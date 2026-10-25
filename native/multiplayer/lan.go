package main

import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/net/ipv4"
)

type lanAnnouncement struct {
	Port   int
	MOTD   string
	Manual bool
}

func parseAnnouncement(data string) (lanAnnouncement, bool) {
	var result lanAnnouncement
	if len(data) > 1024 || !strings.HasPrefix(data, "[MOTD]") {
		return result, false
	}
	parts := strings.SplitN(strings.TrimPrefix(data, "[MOTD]"), "[/MOTD][AD]", 2)
	if len(parts) != 2 || !strings.HasSuffix(parts[1], "[/AD]") {
		return result, false
	}
	port, err := strconv.Atoi(strings.TrimSuffix(parts[1], "[/AD]"))
	if err != nil || port < 1 || port > 65535 || !utf8.ValidString(parts[0]) || len(parts[0]) > 240 {
		return result, false
	}
	return lanAnnouncement{Port: port, MOTD: parts[0]}, true
}

func physicalInterfaces() []net.Interface {
	all, _ := net.Interfaces()
	var result []net.Interface
	for _, iface := range all {
		if iface.Flags&net.FlagUp != 0 && iface.Flags&net.FlagMulticast != 0 &&
			iface.Flags&(net.FlagLoopback|net.FlagPointToPoint) == 0 {
			result = append(result, iface)
		}
	}
	return result
}

func localAddress(ip net.IP) bool {
	if ip.IsLoopback() {
		return true
	}
	all, _ := net.InterfaceAddrs()
	for _, raw := range all {
		own, _, err := net.ParseCIDR(raw.String())
		if err == nil && own.Equal(ip) {
			return true
		}
	}
	return false
}

func (s *session) captureLAN() {
	for _, iface := range physicalInterfaces() {
		conn, err := net.ListenMulticastUDP("udp4", &iface, &net.UDPAddr{IP: net.IPv4(224, 0, 2, 60), Port: 4445})
		if err != nil {
			continue
		}
		go func(c *net.UDPConn) { <-s.ctx.Done(); _ = c.Close() }(conn)
		go func(c *net.UDPConn) {
			defer c.Close()
			buf := make([]byte, 2048)
			for {
				n, addr, err := c.ReadFromUDP(buf)
				if err != nil {
					return
				}
				if !localAddress(addr.IP) {
					continue
				}
				announcement, ok := parseAnnouncement(string(buf[:n]))
				if !ok {
					continue
				}
				select {
				case s.share <- announcement:
				default:
				}
			}
		}(conn)
	}
}

func announceLocal(port int, motd string) {
	motd = strings.NewReplacer("[", "(", "]", ")").Replace(motd)
	payload := []byte(fmt.Sprintf("[MOTD]%s[/MOTD][AD]%d[/AD]", motd, port))
	for _, iface := range physicalInterfaces() {
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			ip, _, err := net.ParseCIDR(address.String())
			if err != nil || ip.To4() == nil {
				continue
			}
			conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ip})
			if err != nil {
				continue
			}
			packet := ipv4.NewPacketConn(conn)
			_ = packet.SetMulticastInterface(&iface)
			_ = packet.SetMulticastLoopback(true)
			_ = packet.SetMulticastTTL(1)
			_, _ = packet.WriteTo(payload, nil, &net.UDPAddr{IP: net.IPv4(224, 0, 2, 60), Port: 4445})
			_ = packet.Close()
			break
		}
	}
}

func (s *session) shareGames() {
	if !s.skipLANDiscovery {
		s.captureLAN()
	}
	ticker := time.NewTicker(1500 * time.Millisecond)
	defer ticker.Stop()
	var selection gameShareSelection
	var published lanAnnouncement
	publish := func(current lanAnnouncement) {
		s.gamePort.Store(int32(current.Port))
		if current.Port != published.Port || current.MOTD != published.MOTD {
			s.emit(event{"type": "game", "port": current.Port, "name": current.MOTD})
			published = current
		}
	}
	probe := func(port int) bool { return minecraftServer(s.ctx, port) }
	for {
		select {
		case <-s.ctx.Done():
			return
		case update := <-s.share:
			accepted, invalid := selection.update(update, time.Now(), probe)
			if invalid {
				s.emit(event{"type": "input_error", "code": "game_not_found"})
			}
			if accepted {
				publish(selection.announcement())
			}
		case now := <-ticker.C:
			selection.refresh(now, probe)
			current := selection.announcement()
			publish(current)
			if s.sendControl(controlMessage{Type: "game", Port: current.Port, Name: current.MOTD}) != nil {
				s.cancel()
				return
			}
		}
	}
}

type gameShareSelection struct {
	selected            lanAnnouncement
	manual, available   bool
	lastSeen, lastProbe time.Time
}

func (s *gameShareSelection) update(update lanAnnouncement, now time.Time, probe func(int) bool) (accepted, invalid bool) {
	if !update.Manual && (s.manual || s.selected.Port != 0 && s.selected.Port != update.Port) {
		return false, false
	}
	if update.Port != 0 && (update.Manual || update.Port != s.selected.Port || !s.available) {
		if !probe(update.Port) {
			return false, update.Manual
		}
		s.lastProbe = now
	}
	if update.Manual {
		s.manual = update.Port != 0
	}
	s.selected = update
	s.available = update.Port != 0
	s.lastSeen = now
	return true, false
}

func (s *gameShareSelection) refresh(now time.Time, probe func(int) bool) {
	if s.manual && s.selected.Port != 0 && now.Sub(s.lastProbe) >= 5*time.Second {
		// Keep the user's selection, but withdraw the address and LAN announcement
		// while that Minecraft service is gone. It may recover on the same port.
		s.available = probe(s.selected.Port)
		s.lastProbe = now
	} else if !s.manual && s.selected.Port != 0 && now.Sub(s.lastSeen) > 10*time.Second {
		s.selected = lanAnnouncement{}
		s.available = false
	}
}

func (s *gameShareSelection) announcement() lanAnnouncement {
	if !s.available {
		return lanAnnouncement{}
	}
	return s.selected
}
