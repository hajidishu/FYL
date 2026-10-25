package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/sctp"
)

func dtlsFixture(t *testing.T, wrongPin bool) (*dtls.Conn, *dtls.Conn) {
	t.Helper()
	a, ap, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	b, bp, err := certificate()
	if err != nil {
		t.Fatal(err)
	}
	x, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	y, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = x.Close(); _ = y.Close() })
	if wrongPin {
		bp = strings.Repeat("0", 64)
	}
	server, err := dtls.Server(x, y.LocalAddr(), pinnedDTLSConfig(a, bp))
	if err != nil {
		t.Fatal(err)
	}
	client, err := dtls.Client(y, x.LocalAddr(), pinnedDTLSConfig(b, ap))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close(); _ = server.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	results := make(chan error, 2)
	go func() { results <- server.HandshakeContext(ctx) }()
	go func() { results <- client.HandshakeContext(ctx) }()
	one, two := <-results, <-results
	if wrongPin {
		if one == nil && two == nil {
			t.Fatal("unapproved certificate accepted")
		}
	} else if one != nil || two != nil {
		t.Fatalf("DTLS handshake: %v %v", one, two)
	}
	return server, client
}

func TestUnapprovedCertificateIsRejected(t *testing.T) { dtlsFixture(t, true) }

func tcpFixture(t *testing.T) (*net.TCPConn, *net.TCPConn) {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	first, err := net.DialTCP("tcp4", nil, listener.Addr().(*net.TCPAddr))
	if err != nil {
		t.Fatal(err)
	}
	second, err := listener.AcceptTCP()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = first.Close(); _ = second.Close() })
	return first, second
}

func TestGameStreamPreservesLargePayloadAndHalfClose(t *testing.T) {
	server, client := dtlsFixture(t, false)
	type associationResult struct {
		a   *sctp.Association
		err error
	}
	accepted := make(chan associationResult, 1)
	go func() {
		a, err := sctp.ServerWithOptions(sctp.WithNetConn(server), sctp.WithBlockWrite(true), sctp.WithMTU(1100))
		accepted <- associationResult{a, err}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	guest, err := sctp.ClientContext(ctx, sctp.WithNetConn(client), sctp.WithBlockWrite(true), sctp.WithMTU(1100))
	if err != nil {
		t.Fatal(err)
	}
	result := <-accepted
	if result.err != nil {
		t.Fatal(result.err)
	}
	host := result.a
	t.Cleanup(func() { _ = guest.Close(); _ = host.Close() })
	gstream, err := guest.OpenStream(2, sctp.PayloadTypeWebRTCBinary)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = gstream.Write([]byte(gameHeader)); err != nil {
		t.Fatal(err)
	}
	hstream, err := host.AcceptStream()
	if err != nil {
		t.Fatal(err)
	}
	header := make([]byte, 64)
	n, err := hstream.Read(header)
	if err != nil || string(header[:n]) != gameHeader {
		t.Fatal("invalid stream open")
	}
	player, guestProxy := tcpFixture(t)
	hostProxy, game := tcpFixture(t)
	hs, gs := newSession(ctx, func(event) {}), newSession(ctx, func(event) {})
	defer hs.cancel()
	defer gs.cancel()
	go hs.bridgeGame(hostProxy, hstream)
	go gs.bridgeGame(guestProxy, gstream)
	payload := bytes.Repeat([]byte{0, 255, 17, 3, 0, 1, 2}, 300000)
	done := make(chan error, 2)
	go func() { _, err := player.Write(payload); _ = player.CloseWrite(); done <- err }()
	go func() {
		incoming, err := io.ReadAll(game)
		if err == nil && !bytes.Equal(incoming, payload) {
			err = io.ErrUnexpectedEOF
		}
		if err == nil {
			_, err = game.Write([]byte("final bytes"))
		}
		_ = game.CloseWrite()
		done <- err
	}()
	_ = player.SetReadDeadline(time.Now().Add(20 * time.Second))
	response, err := io.ReadAll(player)
	if err != nil || string(response) != "final bytes" {
		t.Fatalf("response: %q %v", response, err)
	}
	for range 2 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
}
