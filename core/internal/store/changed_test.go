package store_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// changedStamp returns the contents of the changed marker, or "" when it is missing.
func changedStamp(t *testing.T, s *store.Store) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(s.Home(), store.ChangedFile))
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// A long-lived writer, such as loam mcp, keeps the database open, and macOS
// reports a modified file only when the writer closes it. Each commit
// rewrites the marker, so the app's feed sees every write.
func TestEachCommitRewritesTheChangedMarker(t *testing.T) {
	s := openStore(t)
	before := changedStamp(t, s)
	p := newPlot(t, s, "Marker")
	afterPlot := changedStamp(t, s)
	if afterPlot == "" || afterPlot == before {
		t.Fatalf("a plot write left the marker at %q", afterPlot)
	}
	if _, err := s.AddWorktree(store.Worktree{PlotID: p.ID, Repo: "/r", Name: "a", Branch: "a", Path: filepath.Join(t.TempDir(), "a")}); err != nil {
		t.Fatal(err)
	}
	if got := changedStamp(t, s); got == afterPlot {
		t.Fatalf("a worktree write, which is not a change, left the marker at %q", got)
	}
}

func TestAFailedWriteLeavesTheMarker(t *testing.T) {
	s := openStore(t)
	newPlot(t, s, "Marker")
	before := changedStamp(t, s)
	if _, err := s.AddWorktree(store.Worktree{PlotID: "nosuchplot", Repo: "/r", Name: "a", Branch: "a", Path: "/p"}); err == nil {
		t.Fatal("want an error for a missing plot")
	}
	if got := changedStamp(t, s); got != before {
		t.Fatalf("a rolled back write moved the marker from %q to %q", before, got)
	}
}
