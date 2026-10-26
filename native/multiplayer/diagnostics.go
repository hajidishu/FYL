package main

// Only explicitly selected public transport metadata crosses IPC. Neither the
// ICE configuration/credentials nor the DTLS connection state is serialized.
func (s *session) reportPath(verified bool) {
	data := event{"identityVerified": verified, "remoteFingerprint": s.remotePin}
	if pair, err := s.agent.GetSelectedCandidatePair(); err == nil && pair != nil {
		data["selectedLocal"] = pair.Local.Marshal()
		data["selectedRemote"] = pair.Remote.Marshal()
	}
	if stats, ok := s.agent.GetSelectedCandidatePairStats(); ok {
		data["iceRTTms"] = stats.CurrentRoundTripTime * 1000
	}
	s.emit(event{"type": "diagnostics", "data": data})
}
