package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/netip"
	"strings"
	"time"

	"github.com/pion/ice/v4"
)

const ticketPrefix = "FYL1:"
const maxTicketBytes = 32768

// Tickets deliberately contain no account information or machine identifiers.
// The offer's secret authorizes one answer; the DTLS certificate pins bind the
// selected ICE path to the exact peer approved through that exchange.
type ticket struct {
	Version    int      `json:"v"`
	Kind       string   `json:"t"`
	Room       string   `json:"r"`
	Expires    int64    `json:"e"`
	Protocol   string   `json:"d"`
	Ufrag      string   `json:"u"`
	Pwd        string   `json:"p"`
	Pin        string   `json:"f"`
	Candidates []string `json:"c"`
	Secret     string   `json:"k,omitempty"`
	MAC        string   `json:"m,omitempty"`
}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func encodeTicket(t ticket) (string, error) {
	b, err := json.Marshal(t)
	if err != nil {
		return "", err
	}
	if len(b) > maxTicketBytes {
		return "", errors.New("ticket_large")
	}
	return ticketPrefix + base64.RawURLEncoding.EncodeToString(b), nil
}

func decodeTicket(text, kind string, now time.Time) (ticket, error) {
	var t ticket
	if len(text) > maxTicketBytes*2 {
		return t, errors.New("ticket_large")
	}
	text = strings.Join(strings.Fields(text), "")
	if !strings.HasPrefix(text, ticketPrefix) {
		return t, errors.New("ticket_invalid")
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(text, ticketPrefix))
	if err != nil || len(b) > maxTicketBytes {
		return t, errors.New("ticket_invalid")
	}
	if err = json.Unmarshal(b, &t); err != nil {
		return t, errors.New("ticket_invalid")
	}
	if t.Version != 1 || t.Protocol != "minecraft-tcp" || t.Kind != kind || len(t.Room) != 22 ||
		len(t.Ufrag) < 4 || len(t.Ufrag) > 256 || len(t.Pwd) < 22 || len(t.Pwd) > 256 ||
		strings.ContainsAny(t.Ufrag+t.Pwd, " \r\n\t:") || len(t.Pin) != 64 ||
		len(t.Candidates) == 0 || len(t.Candidates) > 32 {
		return t, errors.New("ticket_invalid")
	}
	if _, err := hex.DecodeString(t.Pin); err != nil {
		return t, errors.New("ticket_invalid")
	}
	if t.Expires <= now.Unix() {
		return t, errors.New("ticket_expired")
	}
	if t.Expires > now.Add(11*time.Minute).Unix() {
		return t, errors.New("ticket_invalid")
	}
	if kind == "offer" {
		key, err := base64.RawURLEncoding.DecodeString(t.Secret)
		if err != nil || len(key) != 32 || t.MAC != "" {
			return t, errors.New("ticket_invalid")
		}
	} else if t.Secret != "" || len(t.MAC) != 43 {
		return t, errors.New("ticket_invalid")
	}
	for _, raw := range t.Candidates {
		if len(raw) > 1024 {
			return t, errors.New("ticket_invalid")
		}
		c, err := ice.UnmarshalCandidate(raw)
		if err != nil {
			return t, errors.New("ticket_invalid")
		}
		ip, err := netip.ParseAddr(c.Address())
		if err != nil || !ip.IsGlobalUnicast() || ip.IsLoopback() ||
			c.Component() != 1 || c.Port() < 1 || c.Port() > 65535 ||
			(c.NetworkType() != ice.NetworkTypeUDP4 && c.NetworkType() != ice.NetworkTypeUDP6) ||
			(c.Type() != ice.CandidateTypeHost && c.Type() != ice.CandidateTypeServerReflexive) {
			return t, errors.New("ticket_invalid")
		}
	}
	return t, nil
}

func answerMAC(t ticket, secret string) (string, error) {
	key, err := base64.RawURLEncoding.DecodeString(secret)
	if err != nil || len(key) != 32 {
		return "", errors.New("ticket_invalid")
	}
	t.MAC = ""
	b, err := json.Marshal(t)
	if err != nil {
		return "", err
	}
	h := hmac.New(sha256.New, key)
	_, _ = h.Write(b)
	return base64.RawURLEncoding.EncodeToString(h.Sum(nil)), nil
}

func validateAnswer(offer, answer ticket) error {
	if answer.Room != offer.Room || answer.Protocol != offer.Protocol || answer.Expires != offer.Expires {
		return errors.New("wrong_room")
	}
	want, err := answerMAC(answer, offer.Secret)
	if err != nil || !hmac.Equal([]byte(want), []byte(answer.MAC)) {
		return errors.New("wrong_room")
	}
	return nil
}
