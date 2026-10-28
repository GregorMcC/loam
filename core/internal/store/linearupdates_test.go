package store_test

import (
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestRunNotesStayWithTheRun(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	r := addTestRun(t, s, p.ID)
	if r.Notes != nil {
		t.Fatalf("a new run has notes: %+v", r.Notes)
	}
	at := time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)
	want := store.RunNotes{
		Walkthrough:   "A link moves by drag.",
		Files:         []store.NoteFile{{Path: "app/drag.swift", Role: "The rule"}},
		Risk:          store.NoteRisk{Level: store.RiskLow, Reasons: []string{"One file."}},
		WhereItStands: "Drag works.",
		WrittenAt:     at,
	}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.Notes = &want; return nil }); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	n := got.Notes
	if n == nil || n.Walkthrough != want.Walkthrough || len(n.Files) != 1 || n.Files[0] != want.Files[0] ||
		n.Risk.Level != store.RiskLow || len(n.Risk.Reasons) != 1 || n.WhereItStands != want.WhereItStands || !n.WrittenAt.Equal(at) {
		t.Fatalf("notes %+v", n)
	}
	// An update that does not touch the notes keeps them, and nil removes them.
	if got, _ = s.UpdateRun(r.ID, func(r *store.Run) error { r.Note = "x"; return nil }); got.Notes == nil {
		t.Fatal("an update lost the notes")
	}
	if got, _ = s.UpdateRun(r.ID, func(r *store.Run) error { r.Notes = nil; return nil }); got.Notes != nil {
		t.Fatalf("notes %+v", got.Notes)
	}
	if got, _ = s.GetRun(r.ID); got.Notes != nil {
		t.Fatalf("notes %+v", got.Notes)
	}
}

func TestLinearUpdatesStartOnExceptTheComment(t *testing.T) {
	s := openStore(t)
	u, err := s.GetLinearUpdates()
	if err != nil || u != store.DefaultLinearUpdates || !u.InProgress || !u.AttachPR || !u.Done || u.WalkthroughComment {
		t.Fatalf("defaults %+v %v", u, err)
	}
	want := store.LinearUpdates{InProgress: false, AttachPR: true, Done: false, WalkthroughComment: true}
	if _, err := s.SetLinearUpdates(want); err != nil {
		t.Fatal(err)
	}
	if u, _ := s.GetLinearUpdates(); u != want {
		t.Fatalf("got %+v", u)
	}
	// A second set replaces the row.
	if _, err := s.SetLinearUpdates(store.DefaultLinearUpdates); err != nil {
		t.Fatal(err)
	}
	if u, _ := s.GetLinearUpdates(); u != store.DefaultLinearUpdates {
		t.Fatalf("got %+v", u)
	}
}
