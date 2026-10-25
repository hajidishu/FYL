package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/pion/sctp"
)

const gameHeader = "FYL-GAME/1"
const controlHello = "FYL-CONTROL/1"

type controlMessage struct {
	Type string `json:"type"`
	Port int    `json:"port,omitempty"`
	Name string `json:"name,omitempty"`
}

func (s *session) sendControl(message controlMessage) error {
	b, err := json.Marshal(message)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.control.SetWriteDeadline(time.Now().Add(15 * time.Second))
	_, err = s.control.Write(b)
	return err
}

func (s *session) gameTunnel() error {
	// Cancellation also interrupts SCTP setup and every blocked stream operation.
	go func() { <-s.ctx.Done(); _ = s.secure.Close() }()
	_ = s.secure.SetDeadline(time.Now().Add(30 * time.Second))
	var err error
	if s.owner {
		s.association, err = sctp.ServerWithOptions(sctp.WithNetConn(s.secure), sctp.WithMTU(1100),
			sctp.WithBlockWrite(true), sctp.WithMaxReceiveBufferSize(1024*1024), sctp.WithMaxMessageSize(65536))
	} else {
		s.association, err = sctp.ClientContext(s.ctx, sctp.WithNetConn(s.secure), sctp.WithMTU(1100),
			sctp.WithBlockWrite(true), sctp.WithMaxReceiveBufferSize(1024*1024), sctp.WithMaxMessageSize(65536))
	}
	if err != nil {
		return errors.New("connection_lost")
	}
	_ = s.secure.SetDeadline(time.Time{})
	setupTimeout := time.AfterFunc(30*time.Second, s.cancel)
	defer setupTimeout.Stop()
	if s.owner {
		s.control, err = s.association.AcceptStream()
	} else {
		s.control, err = s.association.OpenStream(0, sctp.PayloadTypeWebRTCBinary)
	}
	if err != nil || s.control.StreamIdentifier() != 0 {
		return errors.New("protocol_error")
	}
	if _, err = s.control.Write([]byte(controlHello)); err != nil {
		return err
	}
	hello := make([]byte, 64)
	n, err := s.control.Read(hello)
	if err != nil || string(hello[:n]) != controlHello {
		return errors.New("protocol_error")
	}
	setupTimeout.Stop()
	var local *net.TCPListener
	var remoteGame atomic.Int32
	var remoteName atomic.Value
	remoteName.Store("FYL Minecraft")
	if s.owner {
		go s.acceptGameStreams()
		go s.shareGames()
	} else {
		// Bind all local addresses for LAN discovery compatibility. Every accepted
		// connection is checked against this machine's own interface addresses.
		local, err = net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4zero})
		if err != nil {
			return errors.New("local_port_failed")
		}
		defer local.Close()
		go func() { <-s.ctx.Done(); _ = local.Close() }()
		go s.acceptLocalGames(local)
		go func() {
			ticker := time.NewTicker(1500 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-s.ctx.Done():
					return
				case <-ticker.C:
					if remoteGame.Load() > 0 {
						announceLocal(local.Addr().(*net.TCPAddr).Port, remoteName.Load().(string))
					}
				}
			}
		}()
	}
	s.connected.Store(true)
	s.state("connected")
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-s.ctx.Done():
				return
			case <-ticker.C:
				if s.sendControl(controlMessage{Type: "heartbeat"}) != nil {
					s.cancel()
					return
				}
				s.emit(event{"type": "stats", "sent": s.sent.Load(), "received": s.received.Load()})
			}
		}
	}()
	buffer := make([]byte, 1024)
	for {
		_ = s.control.SetReadDeadline(time.Now().Add(45 * time.Second))
		n, err := s.control.Read(buffer)
		if err != nil {
			return errors.New("connection_lost")
		}
		var message controlMessage
		if json.Unmarshal(buffer[:n], &message) != nil {
			return errors.New("protocol_error")
		}
		if message.Type == "heartbeat" {
			continue
		}
		if message.Type != "game" || s.owner || message.Port < 0 || message.Port > 65535 || len(message.Name) > 240 || !utf8.ValidString(message.Name) {
			return errors.New("protocol_error")
		}
		name := "FYL Minecraft"
		if message.Name != "" {
			name = "FYL · " + message.Name
		}
		previousName := remoteName.Swap(name).(string)
		if int(remoteGame.Swap(int32(message.Port))) != message.Port || previousName != name {
			address := ""
			if message.Port > 0 {
				address = net.JoinHostPort("127.0.0.1", strconv.Itoa(local.Addr().(*net.TCPAddr).Port))
			}
			s.emit(event{"type": "game", "port": message.Port, "name": message.Name, "address": address})
		}
	}
}

func (s *session) acceptGameStreams() {
	limit := make(chan struct{}, 16)
	for {
		stream, err := s.association.AcceptStream()
		if err != nil {
			s.cancel()
			return
		}
		if stream.StreamIdentifier() == 0 {
			_ = stream.Close()
			continue
		}
		select {
		case limit <- struct{}{}:
		default:
			_ = stream.Close()
			continue
		}
		go func() {
			defer func() { <-limit }()
			defer stream.Close()
			_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
			header := make([]byte, 64)
			n, err := stream.Read(header)
			if err != nil || string(header[:n]) != gameHeader {
				return
			}
			port := int(s.gamePort.Load())
			if port < 1 || !minecraftServer(s.ctx, port) {
				return
			}
			// The peer cannot choose an address or port. Only the locally selected
			// Minecraft world on loopback can ever be reached through this session.
			dialer := net.Dialer{Timeout: 8 * time.Second}
			conn, err := dialer.DialContext(s.ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
			if err != nil {
				return
			}
			s.bridgeGame(conn.(*net.TCPConn), stream)
		}()
	}
}

func (s *session) acceptLocalGames(server *net.TCPListener) {
	limit := make(chan struct{}, 16)
	next := uint32(0)
	for {
		client, err := server.AcceptTCP()
		if err != nil {
			return
		}
		if !localAddress(client.RemoteAddr().(*net.TCPAddr).IP) {
			_ = client.Close()
			continue
		}
		select {
		case limit <- struct{}{}:
		default:
			_ = client.Close()
			continue
		}
		next += 2
		if next > 65534 {
			_ = client.Close()
			s.cancel()
			return
		}
		id := uint16(next)
		go func() {
			defer func() { <-limit }()
			stream, err := s.association.OpenStream(id, sctp.PayloadTypeWebRTCBinary)
			if err != nil {
				_ = client.Close()
				return
			}
			_ = stream.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err = stream.Write([]byte(gameHeader)); err != nil {
				_ = client.Close()
				_ = stream.Close()
				return
			}
			s.bridgeGame(client, stream)
		}()
	}
}

func (s *session) bridgeGame(local *net.TCPConn, stream *sctp.Stream) {
	defer local.Close()
	defer stream.Close()
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	go func() { <-ctx.Done(); _ = local.Close(); _ = stream.SetDeadline(time.Now()) }()
	done := make(chan error, 1)
	go func() {
		buffer := make([]byte, 16384)
		for {
			_ = local.SetReadDeadline(time.Now().Add(2 * time.Minute))
			n, err := local.Read(buffer)
			if n > 0 {
				_ = stream.SetWriteDeadline(time.Now().Add(30 * time.Second))
				if _, writeErr := stream.Write(buffer[:n]); writeErr != nil {
					done <- writeErr
					cancel()
					return
				}
				s.sent.Add(uint64(n))
			}
			if err != nil {
				_ = stream.Close()
				done <- err
				if err != io.EOF {
					cancel()
				}
				return
			}
		}
	}()
	buffer := make([]byte, 65536)
	for {
		_ = stream.SetReadDeadline(time.Now().Add(2 * time.Minute))
		n, err := stream.Read(buffer)
		if n > 0 {
			_ = local.SetWriteDeadline(time.Now().Add(30 * time.Second))
			if _, writeErr := local.Write(buffer[:n]); writeErr != nil {
				cancel()
				break
			}
			s.received.Add(uint64(n))
		}
		if err != nil {
			_ = local.CloseWrite()
			if err != io.EOF {
				cancel()
			}
			break
		}
	}
	select {
	case <-done:
	case <-ctx.Done():
	}
}
