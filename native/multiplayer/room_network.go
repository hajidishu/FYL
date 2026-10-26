package main

import (
	"context"
	"errors"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/stun/v4"
	"github.com/pion/transport/v5/stdnet"
)

type roomSocket struct {
	mux    *ice.UniversalUDPMuxDefault
	local  *net.UDPAddr
	server net.Addr
	mapped atomic.Pointer[stun.XORMappedAddress]
}

// The room owns these sockets for its whole lifetime. Closing a peer removes
// only that peer's ufrag from the mux, never the shared physical socket.
type roomNetwork struct {
	config  ice.AgentConfig
	mux     *ice.MultiUDPMuxDefault
	sockets []*roomSocket
}

func newRoomNetwork(base *ice.AgentConfig) (*roomNetwork, error) {
	if base == nil {
		base = defaultICEConfig()
	}
	n := &roomNetwork{config: *base}
	if n.config.Net == nil {
		var err error
		n.config.Net, err = stdnet.NewNet()
		if err != nil {
			return nil, err
		}
	}
	interfaces, err := n.config.Net.Interfaces()
	if err != nil {
		return nil, err
	}
	var muxes []ice.UDPMux
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || base.InterfaceFilter != nil && !base.InterfaceFilter(iface.Name) {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, addr := range addresses {
			ip, _, err := net.ParseCIDR(addr.String())
			if err != nil || !ip.IsGlobalUnicast() || ip.IsLoopback() ||
				base.IPFilter != nil && !base.IPFilter(ip) || len(n.sockets) >= 16 {
				continue
			}
			network := "udp6"
			if ip.To4() != nil {
				network = "udp4"
			}
			allowed := len(base.NetworkTypes) == 0
			for _, kind := range base.NetworkTypes {
				allowed = allowed || kind.String() == network
			}
			if !allowed {
				continue
			}
			conn, err := n.config.Net.ListenPacket(network, net.JoinHostPort(ip.String(), "0"))
			if err != nil {
				continue
			}
			mux := ice.NewUniversalUDPMuxDefault(ice.UniversalUDPMuxParams{
				UDPConn: conn, Net: n.config.Net, XORMappedAddrCacheTTL: 10 * time.Second,
			})
			socket := &roomSocket{mux: mux, local: conn.LocalAddr().(*net.UDPAddr)}
			for _, uri := range base.Urls {
				if uri.Scheme == stun.SchemeTypeSTUN {
					socket.server, _ = n.config.Net.ResolveUDPAddr(network, net.JoinHostPort(uri.Host, strconv.Itoa(uri.Port)))
					break
				}
			}
			n.sockets = append(n.sockets, socket)
			muxes = append(muxes, mux)
		}
	}
	if len(muxes) == 0 {
		return nil, errors.New("no_candidates")
	}
	n.mux = ice.NewMultiUDPMuxDefault(muxes...)
	n.config.UDPMux = n.mux
	// Host candidates already use the shared sockets. Advertise their STUN
	// aliases in the invitation separately, so both IPv4 and IPv6 keep their
	// correct socket/mapping and no extra ephemeral ICE ports are allocated.
	n.config.UDPMuxSrflx = nil
	n.config.Urls = nil
	n.config.CandidateTypes = []ice.CandidateType{ice.CandidateTypeHost}
	return n, nil
}

func (n *roomNetwork) refresh(ctx context.Context) {
	var work sync.WaitGroup
	for _, socket := range n.sockets {
		if socket.server == nil {
			continue
		}
		work.Add(1)
		go func(s *roomSocket) {
			defer work.Done()
			mapped, err := s.mux.GetXORMappedAddrContext(ctx, s.server, 5*time.Second)
			if err == nil && mapped.IP.IsGlobalUnicast() && !mapped.IP.IsLoopback() {
				s.mapped.Store(mapped)
			}
		}(socket)
	}
	work.Wait()
}

func (n *roomNetwork) candidates(host []string) []string {
	result := append([]string(nil), host...)
	for _, socket := range n.sockets {
		mapped := socket.mapped.Load()
		if mapped == nil || len(result) >= 32 || mapped.IP.Equal(socket.local.IP) && mapped.Port == socket.local.Port {
			continue
		}
		candidate, err := ice.NewCandidateServerReflexive(&ice.CandidateServerReflexiveConfig{
			Network: "udp", Address: mapped.IP.String(), Port: mapped.Port, Component: 1,
			RelAddr: socket.local.IP.String(), RelPort: socket.local.Port,
		})
		if err == nil {
			result = append(result, candidate.Marshal())
		}
	}
	return result
}
