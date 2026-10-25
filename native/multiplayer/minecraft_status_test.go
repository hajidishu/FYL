package main

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestMinecraftPortValidationRejectsOtherServices(t *testing.T) {
	for _, minecraft := range []bool{true, false} {
		listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = listener.Close() })
		go func() {
			for {
				conn, err := listener.AcceptTCP()
				if err != nil {
					return
				}
				func() {
					defer conn.Close()
					_ = conn.SetDeadline(time.Now().Add(time.Second))
					reader := bufio.NewReader(conn)
					size, err := getVarint(reader)
					if err != nil || size > 1024 {
						return
					}
					if _, err = io.CopyN(io.Discard, reader, int64(size)); err != nil {
						return
					}
					if !minecraft {
						_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
						return
					}
					if size, err = getVarint(reader); err != nil || size != 1 {
						return
					}
					if packet, err := reader.ReadByte(); err != nil || packet != 0 {
						return
					}
					data := []byte(`{"version":{"name":"1.21.1","protocol":767},"players":{"max":20,"online":0},"description":"World"}`)
					var packet bytes.Buffer
					putVarint(&packet, 0)
					putVarint(&packet, uint32(len(data)))
					_, _ = packet.Write(data)
					var response bytes.Buffer
					putVarint(&response, uint32(packet.Len()))
					_, _ = response.Write(packet.Bytes())
					_, _ = conn.Write(response.Bytes())
				}()
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		matched := minecraftServer(ctx, listener.Addr().(*net.TCPAddr).Port)
		cancel()
		if matched != minecraft {
			t.Fatalf("service classification: got %v want %v", matched, minecraft)
		}
		_ = listener.Close()
	}
}
