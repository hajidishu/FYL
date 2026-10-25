package main

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func fixtureTicket(t *testing.T) ticket {
	t.Helper()
	secret, err := randomToken(32)
	if err != nil {
		t.Fatal(err)
	}
	room, err := randomToken(16)
	if err != nil {
		t.Fatal(err)
	}
	return ticket{Version: 1, Protocol: "minecraft-tcp", Kind: "offer", Room: room, Expires: time.Now().Add(time.Minute).Unix(),
		Ufrag: "host", Pwd: strings.Repeat("a", 24), Pin: strings.Repeat("0", 64), Secret: secret,
		Candidates: []string{"1 1 udp 2130706431 198.51.100.1 50000 typ host"}}
}

func TestAnswerIsBoundToRoomAndCertificate(t *testing.T) {
	offer := fixtureTicket(t)
	answer := offer
	answer.Kind = "answer"
	answer.Secret = ""
	var err error
	answer.MAC, err = answerMAC(answer, offer.Secret)
	if err != nil {
		t.Fatal(err)
	}
	if err = validateAnswer(offer, answer); err != nil {
		t.Fatal(err)
	}
	answer.Pin = strings.Repeat("1", 64)
	if validateAnswer(offer, answer) == nil {
		t.Fatal("changed peer identity was accepted")
	}
	answer = offer
	answer.Kind = "answer"
	answer.Secret = ""
	answer.Room = "different-room-id-xxxx"
	answer.MAC, _ = answerMAC(answer, offer.Secret)
	if validateAnswer(offer, answer) == nil {
		t.Fatal("answer from another room was accepted")
	}
}

func TestTicketRejectsExpiredUnexpectedTransportAndLoopback(t *testing.T) {
	for _, change := range []func(*ticket){
		func(v *ticket) { v.Expires = time.Now().Add(-time.Minute).Unix() },
		func(v *ticket) { v.Protocol = "system-vpn" },
		func(v *ticket) { v.Candidates = []string{"1 1 udp 2130706431 127.0.0.1 50000 typ host"} },
		func(v *ticket) {
			v.Candidates = []string{"1 1 tcp 2130706431 198.51.100.1 50000 typ host tcptype passive"}
		},
		func(v *ticket) { v.Candidates = make([]string, 33) },
	} {
		v := fixtureTicket(t)
		change(&v)
		text, err := encodeTicket(v)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = decodeTicket(text, "offer", time.Now()); err == nil {
			t.Fatal("invalid ticket accepted")
		}
	}
	v := fixtureTicket(t)
	text, err := encodeTicket(v)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = decodeTicket("\n"+text[:25]+"\n"+text[25:]+"\n", "offer", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err = decodeTicket(text, "answer", time.Now()); err == nil {
		t.Fatal("offer accepted as answer")
	}
	if _, err = decodeTicket(ticketPrefix+base64.RawURLEncoding.EncodeToString(make([]byte, 40000)), "offer", time.Now()); err == nil {
		t.Fatal("oversized ticket accepted")
	}
}

func TestLANAnnouncementCannotSelectAnAddress(t *testing.T) {
	valid, ok := parseAnnouncement("[MOTD]My World[/MOTD][AD]25565[/AD]")
	if !ok || valid.Port != 25565 || valid.MOTD != "My World" {
		t.Fatal("valid announcement rejected")
	}
	for _, data := range []string{"[MOTD]world[/MOTD][AD]127.0.0.1:80[/AD]", "[MOTD]world[/MOTD][AD]0[/AD]", "[MOTD]world[/MOTD][AD]65536[/AD]"} {
		if _, ok := parseAnnouncement(data); ok {
			t.Fatal("invalid game announcement accepted")
		}
	}
}
