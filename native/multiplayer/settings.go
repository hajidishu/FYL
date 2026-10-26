package main

import (
	"errors"
	"net"
	"strings"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/stun/v4"
)

type networkSettings struct {
	AddressFamily     string   `json:"addressFamily"`
	InterfaceName     string   `json:"interfaceName"`
	STUNServers       []string `json:"stunServers"`
	LocalPort         int      `json:"localPort"`
	STUNTimeout       int      `json:"stunTimeout"`
	ConnectTimeout    int      `json:"connectTimeout"`
	InvitationMinutes int      `json:"invitationMinutes"`
	MaxPeers          int      `json:"maxPeers"`
	DiscoverLAN       bool     `json:"discoverLAN"`
	AnnounceLAN       bool     `json:"announceLAN"`
}

func defaultNetworkSettings() *networkSettings {
	return &networkSettings{AddressFamily: "both", STUNServers: []string{"stun:stun.cloudflare.com:3478"},
		STUNTimeout: 5, ConnectTimeout: 45, InvitationMinutes: 10, MaxPeers: 16, DiscoverLAN: true, AnnounceLAN: true}
}

func (s *networkSettings) validate() error {
	for _, character := range s.InterfaceName {
		if character < 32 {
			return errors.New("invalid_settings")
		}
	}
	if (s.AddressFamily != "both" && s.AddressFamily != "ipv4" && s.AddressFamily != "ipv6") ||
		len(s.InterfaceName) > 256 || strings.ContainsAny(s.InterfaceName, "\x00\r\n\t") ||
		s.LocalPort < 0 || s.LocalPort > 65535 || s.STUNTimeout < 1 || s.STUNTimeout > 10 ||
		s.ConnectTimeout < 10 || s.ConnectTimeout > 120 || s.InvitationMinutes < 1 || s.InvitationMinutes > 10 ||
		s.MaxPeers < 1 || s.MaxPeers > maxRoomPeers || len(s.STUNServers) > 8 {
		return errors.New("invalid_settings")
	}
	for _, raw := range s.STUNServers {
		uri, err := stun.ParseURI(raw)
		if err != nil || len(raw) > 512 || uri.Scheme != stun.SchemeTypeSTUN || uri.Proto != stun.ProtoTypeUDP ||
			uri.Port < 1 || uri.Port > 65535 || strings.ContainsAny(raw, " \r\n\t?#/@") {
			return errors.New("invalid_settings")
		}
	}
	return nil
}

func (s *networkSettings) iceConfig() *ice.AgentConfig {
	config := defaultICEConfig()
	config.Urls = nil
	for _, raw := range s.STUNServers {
		uri, _ := stun.ParseURI(raw) // Validated before starting the session.
		config.Urls = append(config.Urls, uri)
	}
	if s.AddressFamily == "ipv4" {
		config.NetworkTypes = []ice.NetworkType{ice.NetworkTypeUDP4}
	} else if s.AddressFamily == "ipv6" {
		config.NetworkTypes = []ice.NetworkType{ice.NetworkTypeUDP6}
	}
	if s.InterfaceName != "" {
		config.InterfaceFilter = func(name string) bool { return name == s.InterfaceName }
	}
	config.IPFilter = func(ip net.IP) bool { return ip.IsGlobalUnicast() && !ip.IsLoopback() }
	timeout := time.Duration(s.STUNTimeout) * time.Second
	config.STUNGatherTimeout = &timeout
	return config
}
