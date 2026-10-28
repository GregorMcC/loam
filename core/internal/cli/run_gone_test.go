package cli

import (
	"database/sql"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-42: a run whose worktree is gone, such as after loam worktree land from
// the sidebar, still has its PR. Loam reads the PR by its number.

// goneRun is a run with PR #1, open, whose worktree was removed. In Shipping
// when ready is false, else Ready.
func goneRun(t *testing.T, ready bool) (*store.Store, store.Run, string) {
	t.Helper()
	var s *store.Store
	var r store.Run
	var w store.Worktree
	if ready {
		s, r, w = readyRun(t)
	} else {
		s, r, w = shipRun(t, "3")
		tick(t)
		r, _ = s.GetRun(r.ID)
	}
	if r.PR == nil || r.PR.Number != 1 {
		t.Fatalf("no PR: %+v", r)
	}
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS")
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	return s, r, state
}

func TestRunTickLandsAShippingRunWhoseWorktreeIsGoneAndPRMerged(t *testing.T) {
	s, r, state := goneRun(t, false)
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunLanded || res.Runs[0].Note != "#1 was merged on GitHub" {
		t.Fatalf("%+v", res)
	}
	if e := events(t, s, r.ID, "land"); !slices.Contains(e, "#1 was merged on GitHub") {
		t.Fatalf("land events %q", e)
	}
}

func TestRunTickMakesAShippingRunWithAnOpenPRReadyWhenItsWorktreeIsGone(t *testing.T) {
	_, _, state := goneRun(t, false)
	setGitHub(t, state)
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunReady ||
		res.Runs[0].Note != "The worktree is gone. Merge #1 on GitHub, or cancel the run" {
		t.Fatalf("%+v", res)
	}
	// The run waits for the merge, and a tick changes nothing.
	if res := tick(t); len(res.Runs) != 0 {
		t.Fatalf("%+v", res)
	}
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	if res := tick(t); len(res.Runs) != 1 || res.Runs[0].State != store.RunLanded {
		t.Fatalf("%+v", res)
	}
}

func TestRunTickStopsAReadyRunWithNoWorktreeWhosePRWasClosed(t *testing.T) {
	_, _, state := goneRun(t, true)
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "CLOSED"`, 1))
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunStopped || res.Runs[0].Note != "#1 was closed on GitHub" {
		t.Fatalf("%+v", res)
	}
}

func TestRunTickKeepsAShippingRunWithNoPRAndNoWorktreeReady(t *testing.T) {
	s, r, w := shipRun(t, "3")
	if err := s.RemoveWorktree(w.ID); err != nil {
		t.Fatal(err)
	}
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunReady || res.Runs[0].Note != "The worktree is gone, so Loam opens no PR" {
		t.Fatalf("%+v %+v", res, r)
	}
}

func TestRunLandOfARunWhoseWorktreeIsGoneAndPRMergedLandsIt(t *testing.T) {
	s, r, state := goneRun(t, true)
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	got, code, out := runLand(t, r.ID)
	if code != 0 || got.Run.State != store.RunLanded || got.Run.Note != "#1 was merged on GitHub" {
		t.Fatalf("exit %d: %s", code, out)
	}
	if r2, _ := s.GetRun(r.ID); r2.State != store.RunLanded {
		t.Fatalf("run %+v", r2)
	}
}

func TestRunLandOfARunWhoseWorktreeIsGoneAndPROpenSaysToMergeIt(t *testing.T) {
	s, r, _ := goneRun(t, true)
	_, code, out := runLand(t, r.ID)
	if code != ExitInvalid || !strings.Contains(out, "#1 is open on GitHub") {
		t.Fatalf("exit %d: %s", code, out)
	}
	if r2, _ := s.GetRun(r.ID); r2.State != store.RunReady {
		t.Fatalf("run %+v", r2)
	}
}

func TestWorktreeLandLandsTheRunsOfTheWorktree(t *testing.T) {
	s, r, w := readyRun(t)
	out, code := loam(t, "worktree", "land", "alpha", w.ID)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunLanded || got.Note != "Merged #1 with squash" {
		t.Fatalf("run %+v", got)
	}
	if !strings.Contains(out, "Landed the run Say hi.") {
		t.Fatalf("output %s", out)
	}
}

func TestWorktreeLandLandsAShippingRunToo(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS"))
	if out, code := loam(t, "worktree", "land", "alpha", w.ID); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunLanded {
		t.Fatalf("run %+v", got)
	}
}

// breakWorktrees renames the worktrees table of the store, so each read of a
// worktree fails with an error that is not [store.ErrNotFound], as a busy or
// locked store does.
func breakWorktrees(t *testing.T) {
	t.Helper()
	db, err := sql.Open("sqlite", filepath.Join(os.Getenv("LOAM_HOME"), "loam.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.Exec(`ALTER TABLE worktrees RENAME TO worktrees_away`); err != nil {
		t.Fatal(err)
	}
}

// A store that cannot read the worktree does not make the run Ready as if
// the worktree were gone: the run waits for the next tick.
func TestRunTickKeepsAShippingRunWhenTheStoreCannotReadItsWorktree(t *testing.T) {
	s, r, _ := shipRun(t, "3")
	breakWorktrees(t)
	res := tick(t)
	if len(res.Runs) != 0 || len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "worktrees") {
		t.Fatalf("%+v", res)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunShipping {
		t.Fatalf("run %+v", got)
	}
}

// Nor does it land a Ready run whose PR GitHub merged, in a tick or in run
// land.
func TestARunWhoseWorktreeTheStoreCannotReadDoesNotLand(t *testing.T) {
	s, r, w := readyRun(t)
	setGitHub(t, strings.Replace(ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS"),
		`"state": "OPEN"`, `"state": "MERGED"`, 1))
	breakWorktrees(t)
	res := tick(t)
	if len(res.Runs) != 0 || len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "worktrees") {
		t.Fatalf("tick %+v", res)
	}
	if _, code, out := runLand(t, r.ID); code == 0 || !strings.Contains(out, "worktrees") {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("run %+v", got)
	}
}
