package main

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"

	"github.com/pion/ice/v4"
	"github.com/pion/logging"
	"github.com/pion/transport/v5/vnet"
)

func TestNetworkSettingsRejectUnsupportedTransportsAndInvalidRanges(t *testing.T) {
	for _, change := range []func(*networkSettings){
		func(s *networkSettings) { s.AddressFamily = "tcp" },
		func(s *networkSettings) { s.LocalPort = 65536 },
		func(s *networkSettings) { s.STUNTimeout = 0 },
		func(s *networkSettings) { s.ConnectTimeout = 1 },
		func(s *networkSettings) { s.InvitationMinutes = 11 },
		func(s *networkSettings) { s.MaxPeers = 17 },
		func(s *networkSettings) { s.STUNServers = []string{"turn:server:3478"} },
		func(s *networkSettings) { s.STUNServers = []string{"stuns:server:5349"} },
		func(s *networkSettings) { s.STUNServers = []string{"stun:server:3478?transport=tcp"} },
	} {
		settings := defaultNetworkSettings()
		change(settings)
		if settings.validate() == nil {
			t.Fatal("invalid settings accepted")
		}
	}
	s := defaultNetworkSettings()
	s.AddressFamily, s.InterfaceName = "ipv6", "eth1"
	s.STUNServers = nil
	if s.validate() != nil {
		t.Fatal("STUN cannot be disabled")
	}
	config := s.iceConfig()
	if len(config.NetworkTypes) != 1 || config.NetworkTypes[0] != ice.NetworkTypeUDP6 || len(config.Urls) != 0 ||
		!config.InterfaceFilter("eth1") || config.InterfaceFilter("eth0") {
		t.Fatal("IP family, interface or STUN settings were ignored")
	}
}

func TestFixedPortConflictDoesNotSilentlyFallBackAndDiagnosticsExcludeCredentials(t *testing.T) {
	network, _ := vnet.NewNet(&vnet.NetConfig{StaticIPs: []string{"192.168.0.1"}})
	router, _ := vnet.NewRouter(&vnet.RouterConfig{CIDR: "192.168.0.0/24", LoggerFactory: logging.NewDefaultLoggerFactory()})
	if err := router.AddNet(network); err != nil {
		t.Fatal(err)
	}
	config := &ice.AgentConfig{Net: network, NetworkTypes: []ice.NetworkType{ice.NetworkTypeUDP4}}
	busy, err := network.ListenPacket("udp4", "192.168.0.1:40000")
	if err != nil {
		t.Fatal(err)
	}
	defer busy.Close()
	if _, err = newRoomNetwork(config, 40000); err == nil || err.Error() != "port_unavailable" {
		t.Fatal("occupied fixed port did not fail explicitly")
	}
	available, err := newRoomNetwork(config, 40001)
	if err != nil {
		t.Fatal(err)
	}
	defer available.mux.Close()
	available.refresh(context.Background())
	data := available.diagnostics([]string{"fixture"})
	encoded, _ := json.Marshal(data)
	if !strings.Contains(string(encoded), "disabled") || strings.Contains(string(encoded), "password") ||
		available.mux.GetListenAddresses()[0].(*net.UDPAddr).Port != 40001 {
		t.Fatal("diagnostics or fixed port did not reflect the active socket")
	}
}
