package store_test

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// addWorktrees adds a worktree to a new plot for each key, so the PR cache
// keeps rows for those keys.
func addWorktrees(t *testing.T, s *store.Store, keys ...store.PRKey) {
	t.Helper()
	p := newPlot(t, s, "Cache")
	for _, k := range keys {
		w := store.Worktree{PlotID: p.ID, Repo: k.Repo, Name: k.Branch, Branch: k.Branch, Path: filepath.Join(t.TempDir(), k.Branch)}
		if _, err := s.AddWorktree(w); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPRCacheSavesAndNotes(t *testing.T) {
	s := openStore(t)
	key := store.PRKey{Repo: "/work/app", Branch: "fix-login"}
	other := store.PRKey{Repo: "/work/app", Branch: "add-search"}
	addWorktrees(t, s, key, other)
	if got, err := s.PRStates(); err != nil || len(got) != 0 {
		t.Fatalf("a new store has cache rows: %v %v", got, err)
	}

	at := time.UnixMilli(time.Now().UnixMilli())
	if err := s.SavePRStates([]store.PRState{{PRKey: key, Data: `{"stage":"draft"}`, CheckedAt: at}}); err != nil {
		t.Fatal(err)
	}
	got, err := s.PRStates()
	if err != nil {
		t.Fatal(err)
	}
	if row := got[key]; row.Data != `{"stage":"draft"}` || !row.CheckedAt.Equal(at) || row.Note != "" {
		t.Fatalf("%+v", row)
	}

	// A note keeps the data and its time, and adds an empty row for a new branch.
	if err := s.NotePRStates("offline", []store.PRKey{key, other}); err != nil {
		t.Fatal(err)
	}
	got, _ = s.PRStates()
	if row := got[key]; row.Data != `{"stage":"draft"}` || !row.CheckedAt.Equal(at) || row.Note != "offline" {
		t.Fatalf("the note lost the data: %+v", row)
	}
	if row := got[other]; row.Data != "" || !row.CheckedAt.IsZero() || row.Note != "offline" {
		t.Fatalf("%+v", row)
	}

	// A save replaces the row and clears the note.
	if err := s.SavePRStates([]store.PRState{{PRKey: key, Data: `{"stage":"merged"}`, CheckedAt: at.Add(time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	got, _ = s.PRStates()
	if row := got[key]; row.Data != `{"stage":"merged"}` || row.Note != "" || !row.CheckedAt.Equal(at.Add(time.Minute)) {
		t.Fatalf("%+v", row)
	}
}

// The app's change feed watches only the changed marker. A cache write that
// moved the marker would make the app list again, and that list could
// refresh again: a loop with no end.
func TestPRCacheWritesLeaveTheChangedMarker(t *testing.T) {
	s := openStore(t)
	key := store.PRKey{Repo: "/work/app", Branch: "fix-login"}
	addWorktrees(t, s, key)
	before := changedStamp(t, s)
	if err := s.SavePRStates([]store.PRState{{PRKey: key, Data: "{}", CheckedAt: time.Now()}}); err != nil {
		t.Fatal(err)
	}
	if err := s.NotePRStates("rate_limited", []store.PRKey{key}); err != nil {
		t.Fatal(err)
	}
	if got := changedStamp(t, s); got != before {
		t.Fatalf("a PR cache write moved the marker from %q to %q", before, got)
	}
	if got, err := s.PRStates(); err != nil || got[key].Note != "rate_limited" {
		t.Fatalf("the writes did not happen: %+v %v", got, err)
	}
}

// A refresh can end after loam worktree rm removed a worktree. The cache
// write then adds no row for it.
func TestPRCacheWritesSkipAWorktreeThatIsGone(t *testing.T) {
	s := openStore(t)
	kept := store.PRKey{Repo: "/work/app", Branch: "fix-login"}
	addWorktrees(t, s, kept)
	gone := store.PRKey{Repo: "/work/app", Branch: "add-search"}
	otherRepo := store.PRKey{Repo: "/work/web", Branch: "fix-login"}
	rows := []store.PRState{{PRKey: kept, Data: "{}"}, {PRKey: gone, Data: "{}"}, {PRKey: otherRepo, Data: "{}"}}
	if err := s.SavePRStates(rows); err != nil {
		t.Fatal(err)
	}
	if err := s.NotePRStates("offline", []store.PRKey{kept, gone, otherRepo}); err != nil {
		t.Fatal(err)
	}
	got, err := s.PRStates()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[kept].Note != "offline" || got[kept].Data != "{}" {
		t.Fatalf("%+v", got)
	}
}

func TestRemoveWorktreeDropsItsPRCacheRow(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "Cache")
	gone, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/work/app", Name: "a", Branch: "a", Path: filepath.Join(t.TempDir(), "a")})
	if err != nil {
		t.Fatal(err)
	}
	kept := store.PRKey{Repo: "/work/app", Branch: "b"}
	addWorktrees(t, s, kept)
	rows := []store.PRState{{PRKey: store.PRKey{Repo: gone.Repo, Branch: gone.Branch}, Data: "{}"}, {PRKey: kept, Data: "{}"}}
	if err := s.SavePRStates(rows); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveWorktree(gone.ID); err != nil {
		t.Fatal(err)
	}
	got, err := s.PRStates()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[kept].Data != "{}" {
		t.Fatalf("%+v", got)
	}
}
