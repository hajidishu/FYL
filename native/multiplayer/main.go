package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"net"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"time"
)

type command struct {
	Type   string `json:"type"`
	Ticket string `json:"ticket"`
	Token  string `json:"token"`
	Port   int    `json:"port"`
}

// The unprivileged helper connects back to a pre-bound loopback listener. There is
// no remotely reachable administration endpoint and no file/shell RPC.
func serve(port int, token string) error {
	if port < 1 || port > 65535 || len(token) != 64 {
		return errors.New("invalid control endpoint")
	}
	conn, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 10*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	encoder := json.NewEncoder(conn)
	var writeMu sync.Mutex
	emit := func(e event) {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_ = encoder.Encode(e)
	}
	emit(event{"type": "hello", "token": token, "version": 1})
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), maxTicketBytes*3)
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	if !scanner.Scan() {
		return errors.New("control authentication failed")
	}
	var auth command
	if json.Unmarshal(scanner.Bytes(), &auth) != nil || auth.Type != "auth" || subtle.ConstantTimeCompare([]byte(auth.Token), []byte(token)) != 1 {
		return errors.New("control authentication failed")
	}
	_ = conn.SetReadDeadline(time.Time{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	defer signal.Stop(interrupts)
	controlDone := make(chan struct{})
	defer close(controlDone)
	go func() {
		select {
		case <-interrupts:
			cancel()
			_ = conn.Close()
		case <-controlDone:
		}
	}()
	emit(event{"type": "ready"})
	var current *session
	var work sync.WaitGroup
	defer func() { cancel(); work.Wait(); emit(event{"type": "stopped"}) }()
	for scanner.Scan() {
		var cmd command
		if json.Unmarshal(scanner.Bytes(), &cmd) != nil {
			return errors.New("invalid command")
		}
		switch cmd.Type {
		case "host", "join":
			if current != nil {
				emit(event{"type": "input_error", "code": "already_started"})
				continue
			}
			current = newSession(ctx, emit)
			work.Add(1)
			go func(owner bool, invitation string, s *session) {
				defer work.Done()
				err := s.run(owner, invitation)
				if ctx.Err() == nil {
					code := "network_failed"
					if err != nil {
						code = err.Error()
					}
					emit(event{"type": "error", "code": code})
				}
			}(cmd.Type == "host", cmd.Ticket, current)
		case "answer":
			if current == nil {
				continue
			}
			select {
			case current.answer <- cmd.Ticket:
			default:
			}
		case "share":
			if current == nil || cmd.Port < 0 || cmd.Port > 65535 {
				continue
			}
			select {
			case current.share <- lanAnnouncement{Port: cmd.Port, MOTD: "FYL Minecraft", Manual: true}:
			case <-current.ctx.Done():
			}
		case "stop":
			return nil
		default:
			return errors.New("invalid command")
		}
	}
	return scanner.Err()
}

func main() {
	port := flag.Int("control-port", 0, "launcher loopback port")
	token := flag.String("control-token", "", "one-use launcher authentication")
	flag.Parse()
	if serve(*port, *token) != nil {
		os.Exit(1)
	}
}
