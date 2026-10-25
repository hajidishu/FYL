package main

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/transport/v5/vnet"
)

func waitSessionEvent(t *testing.T, ctx context.Context, events <-chan event, kind string, predicate func(event) bool) event {
	t.Helper()
	for {
		select {
		case e := <-events:
			if e["type"] == "error" {
				t.Fatalf("session error: %v", e)
			}
			if e["type"] == kind && (predicate == nil || predicate(e)) {
				return e
			}
		case <-ctx.Done():
			t.Fatal("timed out waiting for " + kind)
			return nil
		}
	}
}

func sessionFixture(t *testing.T) (*session, *session, <-chan event, <-chan event, context.Context) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	hEvents, gEvents := make(chan event, 64), make(chan event, 64)
	host := newSession(ctx, func(e event) { hEvents <- e })
	guest := newSession(ctx, func(e event) { gEvents <- e })
	host.skipLANDiscovery = true
	guest.skipLANDiscovery = true
	router, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: "192.168.0.0/24", LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err != nil {
		t.Fatal(err)
	}
	for i, s := range []*session{host, guest} {
		ip := []string{"192.168.0.1", "192.168.0.2"}[i]
		network, err := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{ip}})
		if err != nil {
			t.Fatal(err)
		}
		if err = router.AddNet(network); err != nil {
			t.Fatal(err)
		}
		s.iceConfig = &ice.AgentConfig{Net: network, NetworkTypes: []ice.NetworkType{ice.NetworkTypeUDP4},
			CandidateTypes: []ice.CandidateType{ice.CandidateTypeHost}, MulticastDNSMode: ice.MulticastDNSModeDisabled}
	}
	if err = router.Start(); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 2)
	t.Cleanup(func() {
		cancel()
		for range 2 {
			select {
			case <-finished:
			case <-time.After(5 * time.Second):
				t.Error("session did not stop")
			}
		}
		_ = router.Stop()
	})
	go func() { finished <- host.run(true, "") }()
	offer := waitSessionEvent(t, ctx, hEvents, "ticket", nil)["text"].(string)
	go func() { finished <- guest.run(false, offer) }()
	answer := waitSessionEvent(t, ctx, gEvents, "ticket", nil)["text"].(string)
	host.answer <- answer
	for _, events := range []<-chan event{hEvents, gEvents} {
		waitSessionEvent(t, ctx, events, "state", func(e event) bool { return e["state"] == "connected" })
	}
	return host, guest, hEvents, gEvents, ctx
}

// ICE uses an in-memory network and no STUN service. The game fixture and proxy
// use loopback only; this never modifies adapters, routes or firewall rules.
func gameServerFixture(t *testing.T) *net.TCPListener {
	t.Helper()
	server, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	go func() {
		for {
			conn, err := server.AcceptTCP()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
				reader := bufio.NewReader(conn)
				first, err := reader.Peek(4)
				if err != nil {
					return
				}
				if string(first) == "GAME" {
					_, _ = reader.Discard(4)
					_, _ = io.Copy(conn, reader)
					return
				}
				size, err := getVarint(reader)
				if err != nil || size > 1024 {
					return
				}
				if _, err = io.CopyN(io.Discard, reader, int64(size)); err != nil {
					return
				}
				if size, err = getVarint(reader); err != nil || size != 1 {
					return
				}
				if id, err := reader.ReadByte(); err != nil || id != 0 {
					return
				}
				data := []byte(`{"version":{"protocol":767},"players":{"online":0},"description":"World"}`)
				var payload, response bytes.Buffer
				putVarint(&payload, 0)
				putVarint(&payload, uint32(len(data)))
				_, _ = payload.Write(data)
				putVarint(&response, uint32(payload.Len()))
				_, _ = response.Write(payload.Bytes())
				_, _ = conn.Write(response.Bytes())
			}()
		}
	}()
	return server
}

func TestFullSessionSharesOnlyTheSelectedGame(t *testing.T) {
	host, _, hEvents, gEvents, ctx := sessionFixture(t)
	server := gameServerFixture(t)
	host.share <- lanAnnouncement{Port: server.Addr().(*net.TCPAddr).Port, MOTD: "Fixture World", Manual: true}
	waitSessionEvent(t, ctx, hEvents, "game", func(e event) bool { return e["port"].(int) > 0 })
	game := waitSessionEvent(t, ctx, gEvents, "game", func(e event) bool { return e["port"].(int) > 0 })
	conn, err := net.DialTimeout("tcp4", game["address"].(string), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	payload := bytes.Repeat([]byte("Minecraft bytes\x00\xff"), 4096)
	writeDone := make(chan error, 1)
	go func() { _, err := conn.Write(append([]byte("GAME"), payload...)); writeDone <- err }()
	received := make([]byte, len(payload))
	if _, err = io.ReadFull(conn, received); err != nil {
		t.Fatal(err)
	}
	if err = <-writeDone; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatal("game bytes changed across the full session")
	}
}

func TestManualWorldDisappearsAfterTheGameCloses(t *testing.T) {
	host, _, _, guestEvents, ctx := sessionFixture(t)
	server := gameServerFixture(t)
	host.share <- lanAnnouncement{Port: server.Addr().(*net.TCPAddr).Port, MOTD: "Closing World", Manual: true}
	waitSessionEvent(t, ctx, guestEvents, "game", func(e event) bool { return e["port"].(int) > 0 })
	_ = server.Close()
	waitCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	unavailable := waitSessionEvent(t, waitCtx, guestEvents, "game", func(e event) bool { return e["port"].(int) == 0 })
	if unavailable["address"] != "" {
		t.Fatal("closed world retained a game address")
	}
}
