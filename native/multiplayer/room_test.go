package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/stun/v4"
	"github.com/pion/transport/v5/vnet"
)

func TestSharedInvitationAcceptsConcurrentGuestsAndIsolatesDisconnects(t *testing.T) {
	testSharedRoom(t, false)
}

func TestSharedInvitationAcrossSeparateSimulatedNATs(t *testing.T) {
	testSharedRoom(t, true)
}

func testSharedRoom(t *testing.T, behindNAT bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	events := make(chan event, 1024)
	host := newRoom(ctx, func(e event) { events <- e })
	host.root.skipLANDiscovery = true
	if behindNAT {
		host.root.options.LocalPort = 40000
		host.root.options.MaxPeers = 3
		host.root.options.InvitationMinutes = 2
		host.root.options.DiscoverLAN = false
	}
	cidr := "192.168.0.0/24"
	if behindNAT {
		cidr = "0.0.0.0/0"
	}
	router, err := vnet.NewRouter(&vnet.RouterConfig{CIDR: cidr, LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err != nil {
		t.Fatal(err)
	}
	var stunURI *stun.URI
	if behindNAT {
		serverNet, failure := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"198.51.100.250"}})
		if failure != nil {
			t.Fatal(failure)
		}
		if failure = router.AddNet(serverNet); failure != nil {
			t.Fatal(failure)
		}
		conn, failure := serverNet.ListenPacket("udp4", "198.51.100.250:3478")
		if failure != nil {
			t.Fatal(failure)
		}
		t.Cleanup(func() { _ = conn.Close() })
		go func() {
			buffer := make([]byte, 2048)
			for {
				n, addr, failure := conn.ReadFrom(buffer)
				if failure != nil {
					return
				}
				request := &stun.Message{Raw: buffer[:n]}
				if request.Decode() != nil || request.Type != stun.BindingRequest {
					continue
				}
				remote := addr.(*net.UDPAddr)
				response, failure := stun.Build(stun.NewTransactionIDSetter(request.TransactionID), stun.BindingSuccess,
					&stun.XORMappedAddress{IP: remote.IP, Port: remote.Port}, stun.Fingerprint)
				if failure == nil {
					_, _ = conn.WriteTo(response.Raw, addr)
				}
			}
		}()
		stunURI = &stun.URI{Scheme: stun.SchemeTypeSTUN, Host: "198.51.100.250", Port: 3478, Proto: stun.ProtoTypeUDP}
	}
	guests := make([]*session, 4)
	guestEvents := make([]chan event, len(guests))
	finished := make([]chan error, len(guests)+1)
	for i := range finished {
		finished[i] = make(chan error, 1)
	}
	for i := 0; i <= len(guests); i++ {
		participantRouter := router
		ip := net.IPv4(192, 168, 0, byte(i+1)).String()
		if behindNAT {
			ip = "10." + strconv.Itoa(i) + ".0.2"
			participantRouter, err = vnet.NewRouter(&vnet.RouterConfig{
				CIDR: "10." + strconv.Itoa(i) + ".0.0/24", StaticIPs: []string{net.IPv4(198, 51, 100, byte(i+1)).String()},
				NATType:       &vnet.NATType{MappingBehavior: vnet.EndpointIndependent, FilteringBehavior: vnet.EndpointAddrPortDependent},
				LoggerFactory: logging.NewDefaultLoggerFactory(),
			})
			if err != nil {
				t.Fatal(err)
			}
			if err = router.AddRouter(participantRouter); err != nil {
				t.Fatal(err)
			}
		}
		network, failure := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{ip}})
		if failure != nil {
			t.Fatal(failure)
		}
		if failure = participantRouter.AddNet(network); failure != nil {
			t.Fatal(failure)
		}
		config := &ice.AgentConfig{Net: network, NetworkTypes: []ice.NetworkType{ice.NetworkTypeUDP4},
			CandidateTypes: []ice.CandidateType{ice.CandidateTypeHost}, MulticastDNSMode: ice.MulticastDNSModeDisabled}
		if behindNAT {
			unreachable := &stun.URI{Scheme: stun.SchemeTypeSTUN, Host: "198.51.100.249", Port: 3478, Proto: stun.ProtoTypeUDP}
			config.Urls = []*stun.URI{unreachable, stunURI}
			timeout := time.Second
			config.STUNGatherTimeout = &timeout
			config.CandidateTypes = []ice.CandidateType{ice.CandidateTypeHost, ice.CandidateTypeServerReflexive}
		}
		if i == 0 {
			host.root.iceConfig = config
		} else {
			e := make(chan event, 256)
			guestEvents[i-1] = e
			guests[i-1] = newSession(ctx, func(value event) { e <- value })
			guests[i-1].iceConfig = config
			guests[i-1].skipLANDiscovery = true
		}
	}
	if err = router.Start(); err != nil {
		t.Fatal(err)
	}
	started := 1
	t.Cleanup(func() {
		cancel()
		for i := 0; i < started; i++ {
			select {
			case <-finished[i]:
			case <-time.After(5 * time.Second):
				t.Errorf("participant %d did not stop", i)
			}
		}
		_ = router.Stop()
	})
	go func() { finished[0] <- host.run() }()
	invitation := waitSessionEvent(t, ctx, events, "ticket", nil)["text"].(string)
	offer, err := decodeTicket(invitation, "offer", time.Now())
	if err != nil || offer.Version != 2 {
		t.Fatalf("not a reusable invitation: %v", err)
	}
	if behindNAT {
		found := false
		fixedPort := false
		for _, raw := range offer.Candidates {
			candidate, failure := ice.UnmarshalCandidate(raw)
			found = found || failure == nil && candidate.Type() == ice.CandidateTypeServerReflexive
			fixedPort = fixedPort || failure == nil && candidate.Type() == ice.CandidateTypeHost && candidate.Port() == 40000
		}
		if !found || !fixedPort || offer.Expires > time.Now().Add(2*time.Minute).Unix() {
			t.Fatal("room did not apply its port, invitation lifetime or STUN fallback settings")
		}
	}
	answers := make([]string, len(guests))
	ids := make([]string, len(guests))
	startGuest := func(i int, invite string) {
		started++
		go func() { finished[i+1] <- guests[i].run(false, invite) }()
	}
	for i := 0; i < 3; i++ {
		startGuest(i, invitation)
	}
	importAnswer := func(i int) {
		answers[i] = waitSessionEvent(t, ctx, guestEvents[i], "ticket", nil)["text"].(string)
		a, failure := decodeTicket(answers[i], "answer", time.Now())
		if failure != nil {
			t.Fatal(failure)
		}
		ids[i] = a.Peer
		host.commands <- command{Type: "answer", Ticket: answers[i]}
	}
	for i := 0; i < 3; i++ {
		importAnswer(i)
	}
	connected := map[string]bool{}
	for len(connected) < 3 {
		e := waitSessionEvent(t, ctx, events, "peer", func(e event) bool { return e["state"] == "connected" || e["state"] == "failed" })
		if e["state"] == "failed" {
			t.Fatalf("peer failed: %v", e)
		}
		connected[e["id"].(string)] = true
	}
	if behindNAT {
		startGuest(3, invitation)
		importAnswer(3)
		if e := waitSessionEvent(t, ctx, events, "input_error", nil); e["code"] != "peer_limit" {
			t.Fatal("configured room capacity was ignored")
		}
	}
	server := gameServerFixture(t)
	host.root.share <- lanAnnouncement{Port: server.Addr().(*net.TCPAddr).Port, MOTD: "Shared World", Manual: true}
	addresses := make([]string, len(guests))
	for i := 0; i < 3; i++ {
		addresses[i] = waitSessionEvent(t, ctx, guestEvents[i], "game", func(e event) bool { return e["port"].(int) > 0 })["address"].(string)
	}
	transfer := func(address string, value byte) error {
		conn, failure := net.DialTimeout("tcp4", address, time.Second)
		if failure != nil {
			return failure
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
		payload := bytes.Repeat([]byte{value, 0, 255}, 40000)
		written := make(chan error, 1)
		go func() { _, failure := conn.Write(append([]byte("GAME"), payload...)); written <- failure }()
		received := make([]byte, len(payload))
		_, failure = io.ReadFull(conn, received)
		if failure != nil {
			return failure
		}
		if failure = <-written; failure != nil {
			return failure
		}
		if !bytes.Equal(received, payload) {
			return io.ErrUnexpectedEOF
		}
		return nil
	}
	var work sync.WaitGroup
	failures := make(chan error, 3)
	for i := 0; i < 3; i++ {
		work.Add(1)
		go func(i int) { defer work.Done(); failures <- transfer(addresses[i], byte(i)) }(i)
	}
	work.Wait()
	for i := 0; i < 3; i++ {
		if failure := <-failures; failure != nil {
			t.Fatal(failure)
		}
	}
	// Reimporting an already approved answer must not create a second session.
	host.commands <- command{Type: "answer", Ticket: answers[0]}
	duplicate := waitSessionEvent(t, ctx, events, "input_error", nil)
	if duplicate["code"] != "answer_used" {
		t.Fatal("duplicate answer accepted")
	}
	host.commands <- command{Type: "remove_peer", Peer: ids[0]}
	waitSessionEvent(t, ctx, events, "peer_removed", nil)
	// A fourth friend uses exactly the original invitation while others play.
	if behindNAT {
		host.commands <- command{Type: "answer", Ticket: answers[3]}
	} else {
		startGuest(3, invitation)
		importAnswer(3)
	}
	waitSessionEvent(t, ctx, events, "peer", func(e event) bool { return e["id"] == ids[3] && e["state"] == "connected" })
	addresses[3] = waitSessionEvent(t, ctx, guestEvents[3], "game", func(e event) bool { return e["port"].(int) > 0 })["address"].(string)
	for _, i := range []int{1, 2, 3} {
		if err = transfer(addresses[i], byte(i+10)); err != nil {
			t.Fatalf("disconnect affected another guest: %v", err)
		}
	}
	host.commands <- command{Type: "pause_invitation"}
	waitSessionEvent(t, ctx, events, "room", func(e event) bool { return e["accepting"] == false })
	host.commands <- command{Type: "answer", Ticket: answers[0]}
	if e := waitSessionEvent(t, ctx, events, "input_error", nil); e["code"] != "invitation_paused" {
		t.Fatal("paused invitation accepted an answer")
	}
	host.commands <- command{Type: "refresh_invitation"}
	renewed := waitSessionEvent(t, ctx, events, "ticket", nil)["text"].(string)
	if renewed == invitation {
		t.Fatal("refresh reused the authorization secret")
	}
	host.commands <- command{Type: "answer", Ticket: answers[0]}
	if e := waitSessionEvent(t, ctx, events, "input_error", nil); e["code"] != "wrong_room" {
		t.Fatal("old answer accepted after renewal")
	}
	// Even with a new valid invitation, an old removed peer identifier must not
	// reappear: stale events and UI removals are keyed by this room-lifetime ID.
	newOffer, _ := decodeTicket(renewed, "offer", time.Now())
	reused, _ := decodeTicket(answers[0], "answer", time.Now())
	reused.Expires = newOffer.Expires
	reused.MAC, _ = answerMAC(reused, newOffer.Secret)
	replayed, _ := encodeTicket(reused)
	host.commands <- command{Type: "answer", Ticket: replayed}
	if e := waitSessionEvent(t, ctx, events, "input_error", nil); e["code"] != "answer_used" {
		t.Fatal("removed peer identifier was reused after renewal")
	}
	if err = transfer(addresses[1], 55); err != nil {
		t.Fatalf("refresh disrupted an existing guest: %v", err)
	}
	_ = server.Close()
	for _, i := range []int{1, 2, 3} {
		unavailable := waitSessionEvent(t, ctx, guestEvents[i], "game", func(e event) bool { return e["port"].(int) == 0 })
		if unavailable["address"] != "" {
			t.Fatal("closed world retained a local address")
		}
	}
}
