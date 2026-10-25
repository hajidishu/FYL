package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

func putVarint(buffer *bytes.Buffer, value uint32) {
	for value >= 128 {
		_ = buffer.WriteByte(byte(value&127) | 128)
		value >>= 7
	}
	_ = buffer.WriteByte(byte(value))
}

func getVarint(reader io.ByteReader) (uint32, error) {
	var value uint32
	for i := 0; i < 5; i++ {
		b, err := reader.ReadByte()
		if err != nil {
			return 0, err
		}
		if i == 4 && b > 15 {
			return 0, errors.New("invalid varint")
		}
		value |= uint32(b&127) << (7 * i)
		if b&128 == 0 {
			return value, nil
		}
	}
	return 0, errors.New("invalid varint")
}

// Check the selected loopback service speaks Minecraft status before sharing.
// No invitation can select a target hostname, LAN address or arbitrary service.
func minecraftServer(ctx context.Context, port int) bool {
	return modernMinecraftStatus(ctx, port) || legacyMinecraftStatus(ctx, port)
}

func modernMinecraftStatus(ctx context.Context, port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	dialer := net.Dialer{Timeout: 2 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	var handshake bytes.Buffer
	putVarint(&handshake, 0)
	putVarint(&handshake, ^uint32(0))
	putVarint(&handshake, 9)
	_, _ = handshake.WriteString("localhost")
	var endpoint [2]byte
	binary.BigEndian.PutUint16(endpoint[:], uint16(port))
	_, _ = handshake.Write(endpoint[:])
	putVarint(&handshake, 1)
	var request bytes.Buffer
	putVarint(&request, uint32(handshake.Len()))
	_, _ = request.Write(handshake.Bytes())
	_, _ = request.Write([]byte{1, 0})
	if _, err = conn.Write(request.Bytes()); err != nil {
		return false
	}
	reader := bufio.NewReader(conn)
	size, err := getVarint(reader)
	if err != nil || size < 3 || size > 131072 {
		return false
	}
	packet := make([]byte, int(size))
	if _, err = io.ReadFull(reader, packet); err != nil {
		return false
	}
	payload := bytes.NewReader(packet)
	id, err := getVarint(payload)
	if err != nil || id != 0 {
		return false
	}
	length, err := getVarint(payload)
	if err != nil || int(length) != payload.Len() {
		return false
	}
	jsonBytes := make([]byte, length)
	_, _ = io.ReadFull(payload, jsonBytes)
	var status struct {
		Version *struct {
			Protocol *int `json:"protocol"`
		} `json:"version"`
		Players json.RawMessage `json:"players"`
	}
	return json.Unmarshal(jsonBytes, &status) == nil && status.Version != nil && status.Version.Protocol != nil && len(status.Players) > 0
}

func legacyMinecraftStatus(ctx context.Context, port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	dialer := net.Dialer{Timeout: 2 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return false
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = conn.Write([]byte{0xfe, 1}); err != nil {
		return false
	}
	var header [3]byte
	if _, err = io.ReadFull(conn, header[:]); err != nil || header[0] != 0xff {
		return false
	}
	length := int(binary.BigEndian.Uint16(header[1:]))
	if length < 3 || length > 4096 {
		return false
	}
	data := make([]byte, length*2)
	if _, err = io.ReadFull(conn, data); err != nil {
		return false
	}
	units := make([]uint16, length)
	for i := range units {
		units[i] = binary.BigEndian.Uint16(data[i*2:])
	}
	text := string(utf16.Decode(units))
	parts := strings.Split(text, "\x00")
	if len(parts) >= 6 && parts[0] == "§1" {
		_, a := strconv.Atoi(parts[1])
		_, b := strconv.Atoi(parts[4])
		_, c := strconv.Atoi(parts[5])
		return a == nil && b == nil && c == nil
	}
	parts = strings.Split(text, "§")
	if len(parts) < 3 {
		return false
	}
	_, a := strconv.Atoi(parts[len(parts)-2])
	_, b := strconv.Atoi(parts[len(parts)-1])
	return a == nil && b == nil
}
