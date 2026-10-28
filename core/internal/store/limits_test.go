package store_test

import (
	"errors"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestRunLimitsHaveDefaultsAndCheckTheirRange(t *testing.T) {
	s := openStore(t)
	if l, err := s.GetRunLimits(); err != nil || l != (store.RunLimits{AtATime: 3, MaxTurns: 40, HoldAt: 80}) {
		t.Fatalf("defaults: %+v %v", l, err)
	}
	want := store.RunLimits{AtATime: 20, MaxTurns: 0, HoldAt: 0}
	if _, err := s.SetRunLimits(want); err != nil {
		t.Fatal(err)
	}
	if l, _ := s.GetRunLimits(); l != want {
		t.Fatalf("got %+v", l)
	}
	for _, bad := range []store.RunLimits{{AtATime: 0}, {AtATime: 21}, {AtATime: 1, MaxTurns: -1}, {AtATime: 1, HoldAt: 101}, {AtATime: 1, HoldAt: -1}} {
		if _, err := s.SetRunLimits(bad); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%+v: %v", bad, err)
		}
	}
}

func TestUsageKeepsTheLastReportOfEachWindow(t *testing.T) {
	s := openStore(t)
	if u, err := s.GetUsage(); err != nil || u.FiveHour != nil || u.SevenDay != nil || u.ReadAt != nil {
		t.Fatalf("before a report: %+v %v", u, err)
	}
	now := time.Now().Truncate(time.Millisecond)
	week := now.Add(72 * time.Hour)
	if _, err := s.RecordUsage(store.Usage{
		FiveHour: &store.UsageWindow{Utilization: 0.18, ResetsAt: now.Add(time.Hour)},
		SevenDay: &store.UsageWindow{Utilization: 0.41, ResetsAt: week},
	}, now); err != nil {
		t.Fatal(err)
	}
	// A report with only the 5-hour window keeps the 7-day window.
	later := now.Add(time.Minute)
	if _, err := s.RecordUsage(store.Usage{FiveHour: &store.UsageWindow{Utilization: 0.2, ResetsAt: now.Add(time.Hour)}}, later); err != nil {
		t.Fatal(err)
	}
	u, err := s.GetUsage()
	if err != nil || u.FiveHour.Utilization != 0.2 || u.SevenDay.Utilization != 0.41 || !u.SevenDay.ResetsAt.Equal(week) || !u.ReadAt.Equal(later) {
		t.Fatalf("%+v %v", u, err)
	}
	if pct, ok := u.WeekPercent(now); !ok || pct != 41 {
		t.Fatalf("week percent %v %v", pct, ok)
	}
	// A window that has started again is not known.
	if _, ok := u.WeekPercent(week.Add(time.Second)); ok {
		t.Fatal("a past window is known")
	}
}

func setState(t *testing.T, s *store.Store, id string, st store.RunState) {
	t.Helper()
	if _, err := s.UpdateRun(id, func(r *store.Run) error { r.State = st; return nil }); err != nil {
		t.Fatal(err)
	}
}

// takeSlot starts the run as a tick does, and returns it.
func takeSlot(t *testing.T, s *store.Store, id string, q *store.RunQueue) store.Run {
	t.Helper()
	r, err := s.TakeSlot(id, q, func(r *store.Run) error {
		r.State, r.Note = store.RunStarting, ""
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestTakeSlotQueuesARunWhenEverySlotIsTaken(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 2, HoldAt: 80}); err != nil {
		t.Fatal(err)
	}
	a, b, c := addTestRun(t, s, p.ID), addTestRun(t, s, p.ID), addTestRun(t, s, p.ID)
	for _, r := range []store.Run{a, b, c} {
		setState(t, s, r.ID, store.RunReady)
	}
	// A run does not count itself.
	for _, r := range []store.Run{a, b} {
		if got := takeSlot(t, s, r.ID, nil); got.State != store.RunStarting || got.Queue != nil {
			t.Fatalf("%s: %+v", r.ID, got)
		}
	}
	q := &store.RunQueue{Model: "opus", Effort: "high"}
	got := takeSlot(t, s, c.ID, q)
	if got.State != store.RunQueued || got.Note != "Waits for a slot: 2 of 2 runs are running" || got.Queue == nil || *got.Queue != *q {
		t.Fatalf("c: %+v", got)
	}
	if note, err := s.SlotHold(c.ID); err != nil || note != got.Note {
		t.Fatalf("slot hold %q %v", note, err)
	}
	// A run that leaves its slot frees it, and the queue goes with the start.
	setState(t, s, b.ID, store.RunReady)
	if got := takeSlot(t, s, c.ID, nil); got.State != store.RunStarting || got.Queue != nil || got.Note != "" {
		t.Fatalf("c after b: %+v", got)
	}
	// A lower limit says that the runs are over it.
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 1}); err != nil {
		t.Fatal(err)
	}
	if note, _ := s.SlotHold(b.ID); note != "Waits for a slot: 2 runs are running, over the limit of 1" {
		t.Fatalf("note %q", note)
	}
}

func TestTakeSlotHoldsARunAtTheWeeksUsage(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	now := time.Now()
	if _, err := s.RecordUsage(store.Usage{SevenDay: &store.UsageWindow{Utilization: 0.82, ResetsAt: now.Add(time.Hour)}}, now); err != nil {
		t.Fatal(err)
	}
	if got := takeSlot(t, s, r.ID, &store.RunQueue{}); got.State != store.RunQueued || got.Note != "Held: the week's usage is at 82%, over the 80% limit" {
		t.Fatalf("%+v", got)
	}
	// A try that the start counts keeps its own note in its event.
	got, err := s.TakeSlot(r.ID, nil, func(r *store.Run) error {
		r.State, r.Note, r.Tries = store.RunRunning, "CI failed on #1: test", r.Tries+1
		return nil
	})
	if err != nil || got.State != store.RunQueued || got.Tries != 1 {
		t.Fatalf("%+v %v", got, err)
	}
	events, _ := s.RunEvents(r.ID)
	if last := events[len(events)-1]; last.Kind != "try" || last.Detail != "CI failed on #1: test" {
		t.Fatalf("events %+v", events)
	}
	// With the hold off, the run starts.
	if _, err := s.SetRunLimits(store.RunLimits{AtATime: 3, MaxTurns: 40}); err != nil {
		t.Fatal(err)
	}
	if got := takeSlot(t, s, r.ID, nil); got.State != store.RunStarting {
		t.Fatalf("hold off: %+v", got)
	}
}

func TestHeldNoteSaysWhenTheUsageIsAtTheLimit(t *testing.T) {
	if got := store.HeldNote(80, 80); got != "Held: the week's usage is at 80%, the limit" {
		t.Fatal(got)
	}
}
