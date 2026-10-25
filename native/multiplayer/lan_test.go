package main

import (
	"testing"
	"time"
)

func TestManualSelectionWithdrawsAndRecoversWithoutSwitchingWorlds(t *testing.T) {
	var selection gameShareSelection
	now := time.Now()
	alive := true
	probe := func(port int) bool { return alive && port == 25565 }
	accepted, invalid := selection.update(lanAnnouncement{Port: 25565, MOTD: "My World", Manual: true}, now, probe)
	if !accepted || invalid {
		t.Fatal("valid selection rejected")
	}
	alive = false
	selection.refresh(now.Add(6*time.Second), probe)
	if selection.announcement().Port != 0 {
		t.Fatal("closed world is still advertised")
	}
	accepted, _ = selection.update(lanAnnouncement{Port: 25566, MOTD: "Another world"}, now.Add(7*time.Second), probe)
	if accepted {
		t.Fatal("manual selection switched to a different world")
	}
	alive = true
	selection.refresh(now.Add(12*time.Second), probe)
	if selection.announcement().Port != 25565 {
		t.Fatal("the selected world did not recover")
	}
	accepted, invalid = selection.update(lanAnnouncement{Port: 25566, Manual: true}, now.Add(13*time.Second), probe)
	if accepted || !invalid || selection.announcement().Port != 25565 {
		t.Fatal("invalid manual selection changed the active world")
	}
}

func TestAutomaticSelectionExpiresAndCanBeRestoredAfterManualMode(t *testing.T) {
	var selection gameShareSelection
	now := time.Now()
	probe := func(int) bool { return true }
	selection.update(lanAnnouncement{Port: 25565, MOTD: "Auto world"}, now, probe)
	selection.refresh(now.Add(11*time.Second), probe)
	if selection.announcement().Port != 0 {
		t.Fatal("old automatic world did not expire")
	}
	selection.update(lanAnnouncement{Port: 25566, Manual: true}, now.Add(12*time.Second), probe)
	selection.update(lanAnnouncement{Port: 0, Manual: true}, now.Add(13*time.Second), probe)
	accepted, invalid := selection.update(lanAnnouncement{Port: 25567, MOTD: "New auto world"}, now.Add(14*time.Second), probe)
	if !accepted || invalid || selection.announcement().Port != 25567 {
		t.Fatal("automatic selection did not resume")
	}
}
