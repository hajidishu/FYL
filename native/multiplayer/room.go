package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

const maxRoomPeers = 16

type roomPeer struct {
	session *session
	mu      sync.Mutex
	enabled bool
	active  bool
	number  int
}

func (p *roomPeer) emit(emit func(event), id string, e event) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.enabled {
		return
	}
	result := event{"type": "peer", "id": id, "number": p.number}
	for key, value := range e {
		if key != "type" {
			result[key] = value
		}
	}
	if e["type"] == "diagnostics" {
		delete(result, "data")
		result["diagnostics"] = e["data"]
	}
	if e["type"] == "state" || e["type"] == "stats" || e["type"] == "diagnostics" {
		emit(result)
	}
}

type peerResult struct {
	id  string
	err error
}

type room struct {
	root      *session
	emit      func(event)
	commands  chan command
	completed chan peerResult
	network   *roomNetwork
	offer     ticket
	accepting bool
	peers     map[string]*roomPeer
	used      map[string]bool
	work      sync.WaitGroup
	next      int
}

func newRoom(ctx context.Context, emit func(event)) *room {
	return &room{root: newSession(ctx, emit), emit: emit,
		commands: make(chan command, 32), completed: make(chan peerResult, 32),
		peers: make(map[string]*roomPeer), used: make(map[string]bool)}
}

func (r *room) invitation() error {
	r.offer = r.root.local
	r.offer.Candidates = r.network.candidates(r.root.local.Candidates)
	r.emit(event{"type": "diagnostics", "data": r.network.diagnostics(r.root.local.Candidates)})
	r.offer.Expires = time.Now().Add(time.Duration(r.root.options.InvitationMinutes) * time.Minute).Unix()
	var err error
	if r.offer.Secret, err = randomToken(32); err != nil {
		return err
	}
	text, err := encodeTicket(r.offer)
	if err != nil {
		return err
	}
	r.accepting = true
	r.emit(event{"type": "ticket", "kind": "offer", "text": text, "expires": r.offer.Expires,
		"room": r.offer.Room, "multi": true})
	r.roomState(false)
	return nil
}

func (r *room) roomState(expired bool) {
	r.emit(event{"type": "room", "accepting": r.accepting, "expired": expired})
}

func (r *room) inputError(err error) {
	r.emit(event{"type": "input_error", "code": err.Error()})
}

func (r *room) run() (err error) {
	s := r.root
	defer func() {
		s.cancel()
		r.work.Wait()
		s.close()
		if r.network != nil {
			_ = r.network.mux.Close()
		}
	}()
	s.owner = true
	s.local = ticket{Version: 2, Protocol: "minecraft-tcp", Kind: "offer"}
	if s.local.Room, err = randomToken(16); err != nil {
		return err
	}
	base := s.iceConfig
	if base == nil {
		base = s.options.iceConfig()
	}
	if r.network, err = newRoomNetwork(base, s.options.LocalPort); err != nil {
		return err
	}
	s.iceConfig = &r.network.config
	if err = s.gather(); err != nil {
		return err
	}
	r.network.refresh(s.ctx)
	if s.ctx.Err() != nil {
		return s.ctx.Err()
	}
	if err = r.invitation(); err != nil {
		return err
	}
	s.state("hosting")
	r.work.Add(2)
	go func() { defer r.work.Done(); s.shareGames() }()
	go func() {
		defer r.work.Done()
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-s.ctx.Done():
				return
			case <-ticker.C:
				r.network.refresh(s.ctx)
				s.emit(event{"type": "diagnostics", "data": r.network.diagnostics(s.local.Candidates)})
			}
		}
	}()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return s.ctx.Err()
		case <-ticker.C:
			if r.accepting && time.Now().Unix() >= r.offer.Expires {
				r.accepting = false
				r.roomState(true)
			}
		case result := <-r.completed:
			if peer := r.peers[result.id]; peer != nil {
				peer.active = false
				code := "connection_lost"
				if result.err != nil {
					code = result.err.Error()
				}
				r.emit(event{"type": "peer", "id": result.id, "number": peer.number, "state": "failed", "code": code})
			}
		case cmd := <-r.commands:
			switch cmd.Type {
			case "answer":
				if err = r.addPeer(cmd.Ticket); err != nil {
					r.inputError(err)
				}
			case "refresh_invitation":
				if err = r.invitation(); err != nil {
					r.inputError(err)
				}
			case "pause_invitation":
				r.accepting = false
				r.roomState(false)
			case "remove_peer":
				if peer := r.peers[cmd.Peer]; peer != nil {
					peer.mu.Lock()
					peer.enabled = false
					peer.mu.Unlock()
					peer.session.cancel()
					delete(r.peers, cmd.Peer)
					r.emit(event{"type": "peer_removed", "id": cmd.Peer})
				}
			}
		}
	}
}

func (r *room) addPeer(text string) error {
	if !r.accepting {
		return errors.New("invitation_paused")
	}
	answer, err := decodeTicket(text, "answer", time.Now())
	if err != nil {
		return err
	}
	if err = validateAnswer(r.offer, answer); err != nil {
		return err
	}
	if r.used[answer.Peer] {
		return errors.New("answer_used")
	}
	active := 0
	for _, peer := range r.peers {
		if peer.active {
			active++
		}
	}
	if active >= r.root.options.MaxPeers {
		return errors.New("peer_limit")
	}
	r.next++
	p := &roomPeer{enabled: true, active: true, number: r.next}
	s := newSession(r.root.ctx, func(e event) { p.emit(r.emit, answer.Peer, e) })
	p.session = s
	s.owner = true
	s.options = r.root.options
	s.sharedWorld = r.root
	s.certificate = r.root.certificate
	s.local = r.offer
	s.local.Secret = ""
	s.local.Candidates = nil
	s.local.Ufrag, s.local.Pwd = peerCredentials(r.offer, answer.Peer)
	config := r.network.config
	config.LocalUfrag, config.LocalPwd = s.local.Ufrag, s.local.Pwd
	s.iceConfig = &config
	r.peers[answer.Peer] = p
	r.used[answer.Peer] = true
	r.emit(event{"type": "peer", "id": answer.Peer, "number": p.number, "state": "connecting"})
	expires := r.offer.Expires
	r.work.Add(1)
	go func() {
		defer r.work.Done()
		failure := s.gather()
		if failure == nil {
			failure = s.connect(answer, expires)
		}
		// No late heartbeat or ICE callback may resurrect a finished peer in UI.
		p.mu.Lock()
		p.enabled = false
		p.mu.Unlock()
		s.close()
		select {
		case r.completed <- peerResult{id: answer.Peer, err: failure}:
		case <-r.root.ctx.Done():
		}
	}()
	return nil
}
