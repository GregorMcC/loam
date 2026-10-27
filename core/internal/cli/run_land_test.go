package cli

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// Ticket 207: Land. You merge a run that is ready, and the run is Landed.

type runLandOut struct {
	Run      store.Run            `json:"run"`
	Land     *worktree.LandResult `json:"land"`
	Warnings []string             `json:"warnings"`
}

// readyRun is shipRun with PR #1 open and CI passed, so the run is Ready.
func readyRun(t *testing.T) (*store.Store, store.Run, store.Worktree) {
	t.Helper()
	s, r, w := shipRun(t, "3")
	tick(t)
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS"))
	tick(t)
	r, _ = s.GetRun(r.ID)
	if r.State != store.RunReady {
		t.Fatalf("not ready: %+v", r)
	}
	return s, r, w
}

func runLand(t *testing.T, args ...string) (runLandOut, int, string) {
	t.Helper()
	out, code := loam(t, append([]string{"run", "land"}, append(args, "--json")...)...)
	var got runLandOut
	if code == 0 {
		if err := json.Unmarshal([]byte(out), &got); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	return got, code, out
}

func TestRunLandMergesThePRAndLandsTheRun(t *testing.T) {
	s, r, w := readyRun(t)
	testutil.FakeLinear(t)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Source = &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	got, code, out := runLand(t, r.ID)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got.Run.State != store.RunLanded || got.Run.Note != "Merged #1 with squash" {
		t.Fatalf("run %+v", got.Run)
	}
	if got.Land == nil || !got.Land.Merged || !got.Land.WorktreeRemoved {
		t.Fatalf("land %s", out)
	}
	if _, err := s.GetWorktree(w.ID); err == nil {
		t.Fatal("the worktree is still there")
	}
	// The session stops before its worktree goes.
	if calls := testutil.FakeClaudeCalls(t); !slices.ContainsFunc(calls, func(c []string) bool {
		return slices.Equal(c, []string{"stop", shipSession[:8]})
	}) {
		t.Fatalf("claude calls %q", calls)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Contains(e, "Moved ENG-523 to Done") {
		t.Fatalf("linear events %q", e)
	}
	if e := events(t, s, r.ID, "land"); !slices.Contains(e, "Merged #1 with squash") {
		t.Fatalf("land events %q", e)
	}
}

func TestRunLandRefusesARunThatIsNotReady(t *testing.T) {
	_, r, _ := shipRun(t, "3")
	_, code, out := runLand(t, r.ID)
	if code != ExitInvalid || !strings.Contains(out, "Ready to land") {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestRunLandDryRunChangesNothing(t *testing.T) {
	s, r, _ := readyRun(t)
	got, code, out := runLand(t, r.ID, "--dry-run")
	if code != 0 || got.Land == nil || !got.Land.DryRun || !got.Land.Ready || got.Run.State != store.RunReady {
		t.Fatalf("exit %d: %s", code, out)
	}
	if r2, _ := s.GetRun(r.ID); r2.State != store.RunReady {
		t.Fatalf("the run moved: %+v", r2)
	}
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "stop") {
			t.Fatalf("a dry run stopped the session: %q", c)
		}
	}
}

func TestRunLandWithAMergeQueueKeepsTheRunReady(t *testing.T) {
	s, r, w := readyRun(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	state := strings.Replace(ciState(w.Branch, head, "SUCCESS"), `"logs"`, `"merge_queue": true, "logs"`, 1)
	setGitHub(t, state)
	got, code, out := runLand(t, r.ID)
	if code != 0 || got.Run.State != store.RunReady || got.Run.Note != "#1 is in the merge queue of main" {
		t.Fatalf("exit %d: %s", code, out)
	}
	// GitHub merges it later, and a tick lands the run.
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunLanded || res.Runs[0].Note != "#1 was merged on GitHub" {
		t.Fatalf("%+v", res)
	}
	if e := events(t, s, r.ID, "land"); !slices.Contains(e, "#1 was merged on GitHub") {
		t.Fatalf("land events %q", e)
	}
}

func TestRunTickLandsAReadyRunWhosePRWasMergedOnGitHub(t *testing.T) {
	_, r, w := readyRun(t)
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS")
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "MERGED"`, 1))
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunLanded {
		t.Fatalf("%+v", res)
	}
}

func TestRunTickStopsAReadyRunWhosePRWasClosed(t *testing.T) {
	_, r, w := readyRun(t)
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS")
	setGitHub(t, strings.Replace(state, `"state": "OPEN"`, `"state": "CLOSED"`, 1))
	res := tick(t)
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunStopped || res.Runs[0].Note != "#1 was closed on GitHub" {
		t.Fatalf("%+v", res)
	}
}

func TestRunDiffShowsTheWorkOfTheRun(t *testing.T) {
	_, r, _ := readyRun(t)
	out, code := loam(t, "run", "diff", r.ID, "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got run.DiffResult
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatal(err)
	}
	if got.Head != testutil.Git(t, r.Folder, "rev-parse", "HEAD") || len(got.Files) != 1 {
		t.Fatalf("%s", out)
	}
	f := got.Files[0]
	if f.Path != "hello.txt" || f.Status != "added" || f.Added != 1 ||
		!slices.Equal(f.Hunks[0].Lines, []run.DiffLine{{Kind: "add", New: 1, Text: "hi there"}}) {
		t.Fatalf("%+v", f)
	}
	if out, code := loam(t, "run", "diff", r.ID); code != 0 || out != "added hello.txt +1 -0\n" {
		t.Fatalf("text: exit %d: %q", code, out)
	}
}
