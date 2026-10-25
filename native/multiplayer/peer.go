package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"math/big"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/ice/v4"
	"github.com/pion/sctp"
	"github.com/pion/stun/v4"
)

type event map[string]any

type session struct {
	ctx              context.Context
	cancel           context.CancelFunc
	emit             func(event)
	answer           chan string
	share            chan lanAnnouncement
	owner            bool
	local            ticket
	certificate      tls.Certificate
	agent            *ice.Agent
	secure           *dtls.Conn
	association      *sctp.Association
	control          *sctp.Stream
	gamePort         atomic.Int32
	writeMu          sync.Mutex
	sent, received   atomic.Uint64
	connected        atomic.Bool
	iceConfig        *ice.AgentConfig
	skipLANDiscovery bool
}

func newSession(ctx context.Context, emit func(event)) *session {
	ctx, cancel := context.WithCancel(ctx)
	return &session{ctx: ctx, cancel: cancel, emit: emit,
		answer: make(chan string, 1), share: make(chan lanAnnouncement, 1)}
}

func (s *session) state(value string) { s.emit(event{"type": "state", "state": value}) }

func certificate() (tls.Certificate, string, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, "", err
	}
	cert := &x509.Certificate{SerialNumber: serial, NotBefore: time.Now().Add(-time.Minute),
		NotAfter: time.Now().Add(24 * time.Hour), KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	hash := sha256.Sum256(der)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, hex.EncodeToString(hash[:]), nil
}

func (s *session) gather() error {
	s.state("gathering")
	var err error
	s.certificate, s.local.Pin, err = certificate()
	if err != nil {
		return err
	}
	config := s.iceConfig
	if config == nil {
		uri, parseErr := stun.ParseURI("stun:stun.cloudflare.com:3478")
		if parseErr != nil {
			return parseErr
		}
		disconnected, failed, gather := 10*time.Second, 10*time.Minute, 5*time.Second
		config = &ice.AgentConfig{
			Urls: []*stun.URI{uri}, NetworkTypes: []ice.NetworkType{ice.NetworkTypeUDP4, ice.NetworkTypeUDP6},
			CandidateTypes:      []ice.CandidateType{ice.CandidateTypeHost, ice.CandidateTypeServerReflexive},
			MulticastDNSMode:    ice.MulticastDNSModeDisabled,
			DisconnectedTimeout: &disconnected, FailedTimeout: &failed, STUNGatherTimeout: &gather,
			IPFilter: func(ip net.IP) bool { return ip.IsGlobalUnicast() && !ip.IsLoopback() },
		}
	}
	s.agent, err = ice.NewAgent(config)
	if err != nil {
		return err
	}
	done := make(chan struct{})
	if err = s.agent.OnCandidate(func(c ice.Candidate) {
		if c == nil {
			close(done)
		}
	}); err != nil {
		return err
	}
	if err = s.agent.OnConnectionStateChange(func(state ice.ConnectionState) {
		if s.connected.Load() && state == ice.ConnectionStateDisconnected {
			s.state("reconnecting")
		}
		if s.connected.Load() && state == ice.ConnectionStateConnected {
			s.state("connected")
		}
	}); err != nil {
		return err
	}
	if err = s.agent.GatherCandidates(); err != nil {
		return err
	}
	select {
	case <-done:
	case <-s.ctx.Done():
		return s.ctx.Err()
	case <-time.After(15 * time.Second):
		return errors.New("gather_timeout")
	}
	candidates, err := s.agent.GetLocalCandidates()
	if err != nil {
		return err
	}
	for _, c := range candidates {
		if len(s.local.Candidates) == 32 {
			break
		}
		s.local.Candidates = append(s.local.Candidates, c.Marshal())
	}
	if len(s.local.Candidates) == 0 {
		return errors.New("no_candidates")
	}
	s.local.Ufrag, s.local.Pwd, err = s.agent.GetLocalUserCredentials()
	return err
}

func (s *session) run(owner bool, invitation string) (err error) {
	s.owner = owner
	defer func() {
		s.cancel()
		if s.secure != nil {
			_ = s.secure.Close()
		}
		if s.association != nil {
			_ = s.association.Close()
		}
		if s.agent != nil {
			_ = s.agent.Close()
		}
	}()
	var offer, remote ticket
	if owner {
		s.local = ticket{Version: 1, Protocol: "minecraft-tcp", Kind: "offer", Expires: time.Now().Add(10 * time.Minute).Unix()}
		if s.local.Room, err = randomToken(16); err != nil {
			return err
		}
		if s.local.Secret, err = randomToken(32); err != nil {
			return err
		}
	} else {
		if offer, err = decodeTicket(invitation, "offer", time.Now()); err != nil {
			return err
		}
		s.local = ticket{Version: 1, Protocol: offer.Protocol, Kind: "answer", Room: offer.Room, Expires: offer.Expires}
	}
	if err = s.gather(); err != nil {
		return err
	}
	if owner {
		offer = s.local
	} else {
		if s.local.MAC, err = answerMAC(s.local, offer.Secret); err != nil {
			return err
		}
	}
	text, err := encodeTicket(s.local)
	if err != nil {
		return err
	}
	s.emit(event{"type": "ticket", "kind": s.local.Kind, "text": text, "expires": s.local.Expires,
		"room": s.local.Room})
	if owner {
		s.state("waiting_answer")
		timer := time.NewTimer(time.Until(time.Unix(offer.Expires, 0)))
		defer timer.Stop()
		for {
			select {
			case answer := <-s.answer:
				remote, err = decodeTicket(answer, "answer", time.Now())
				if err == nil {
					err = validateAnswer(offer, remote)
				}
				if err != nil {
					s.emit(event{"type": "input_error", "code": err.Error()})
					continue
				}
			case <-timer.C:
				return errors.New("ticket_expired")
			case <-s.ctx.Done():
				return s.ctx.Err()
			}
			break
		}
	} else {
		remote = offer
	}
	s.state("connecting")
	for _, raw := range remote.Candidates {
		c, err := ice.UnmarshalCandidate(raw)
		if err != nil {
			return errors.New("ticket_invalid")
		}
		if err = s.agent.AddRemoteCandidate(c); err != nil {
			return err
		}
	}
	deadline := time.Unix(offer.Expires, 0)
	if owner && deadline.After(time.Now().Add(45*time.Second)) {
		deadline = time.Now().Add(45 * time.Second)
	}
	connectCtx, cancel := context.WithDeadline(s.ctx, deadline)
	defer cancel()
	var connection *ice.Conn
	if owner {
		connection, err = s.agent.Dial(connectCtx, remote.Ufrag, remote.Pwd)
	} else {
		connection, err = s.agent.Accept(connectCtx, remote.Ufrag, remote.Pwd)
	}
	if err != nil {
		return errors.New("direct_failed")
	}
	s.state("securing")
	config := pinnedDTLSConfig(s.certificate, remote.Pin)
	packetConn := &icePackets{connection}
	if owner {
		s.secure, err = dtls.Server(packetConn, connection.RemoteAddr(), config)
	} else {
		s.secure, err = dtls.Client(packetConn, connection.RemoteAddr(), config)
	}
	if err != nil {
		return err
	}
	handshakeCtx, handshakeCancel := context.WithTimeout(s.ctx, 30*time.Second)
	defer handshakeCancel()
	if err = s.secure.HandshakeContext(handshakeCtx); err != nil {
		return errors.New("peer_identity")
	}
	s.state("configuring")
	return s.gameTunnel()
}

func pinnedDTLSConfig(cert tls.Certificate, pin string) *dtls.Config {
	return &dtls.Config{
		Certificates: []tls.Certificate{cert},
		CipherSuites: []dtls.CipherSuiteID{dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
		ClientAuth:   dtls.RequireAnyClientCert,
		// CA/hostname validation is replaced by the peer's exact certificate pin.
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(certs [][]byte, _ [][]*x509.Certificate) error {
			if len(certs) != 1 {
				return errors.New("peer_identity")
			}
			hash := sha256.Sum256(certs[0])
			expected, _ := hex.DecodeString(pin)
			if subtle.ConstantTimeCompare(hash[:], expected) != 1 {
				return errors.New("peer_identity")
			}
			return nil
		},
		MTU: 1200, ReplayProtectionWindow: 1024,
	}
}

type icePackets struct{ *ice.Conn }

func (c *icePackets) ReadFrom(b []byte) (int, net.Addr, error) {
	n, err := c.Read(b)
	return n, c.RemoteAddr(), err
}
func (c *icePackets) WriteTo(b []byte, _ net.Addr) (int, error) { return c.Write(b) }
