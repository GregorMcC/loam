package store_test

import (
	"errors"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// A land that waits for GitHub stays on the worktree record until a later
// land clears it. It is not a change.
func TestPendingLand(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	w, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: "fix-login", Branch: "fix-login", Path: "/home/w/app-fix-login"})
	if err != nil {
		t.Fatal(err)
	}
	if w.Land != nil {
		t.Fatalf("a new worktree has a pending land: %+v", w.Land)
	}
	before, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID})

	want := store.PendingLand{PR: 15, Method: "squash", Auto: true, KeepRemoteBranch: true}
	if err := s.SetPendingLand(w.ID, &want); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetWorktree(w.ID)
	if err != nil || got.Land == nil || *got.Land != want {
		t.Fatalf("%+v %v", got.Land, err)
	}
	if all, _ := s.ListWorktrees(p.ID); len(all) != 1 || all[0].Land == nil || *all[0].Land != want {
		t.Fatalf("%+v", all)
	}

	if err := s.SetPendingLand(w.ID, nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetWorktree(w.ID); got.Land != nil {
		t.Fatalf("not cleared: %+v", got.Land)
	}
	if err := s.SetPendingLand("nosuchwtree", &want); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%v", err)
	}
	if after, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID}); len(after) != len(before) {
		t.Fatalf("change log grew from %d to %d", len(before), len(after))
	}
}
