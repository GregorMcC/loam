package cli

import (
	"encoding/json"
	"path/filepath"
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

// A land that GitHub would refuse, here for a PR head that you did not look
// at, leaves the session of the run, which stays Ready.
func TestRunLandThatRefusesKeepsTheSession(t *testing.T) {
	s, r, _ := readyRun(t)
	stops := func() int {
		return len(slices.DeleteFunc(testutil.FakeClaudeCalls(t), func(c []string) bool { return len(c) == 0 || c[0] != "stop" }))
	}
	before := stops()
	if _, code, out := runLand(t, r.ID, "--head", strings.Repeat("0", 40)); code == 0 {
		t.Fatalf("landed with another head: %s", out)
	}
	if got := stops(); got != before {
		t.Fatalf("%d claude stop calls, want %d", got, before)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("run %+v", got)
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

// TAS-53: a commit in the worktree after the run is Ready is not on the PR. A tick pushes it, and the run is Shipping
// again, so CI reads it before you merge.
func TestRunTickShipsACommitAfterReadyAgain(t *testing.T) {
	s, r, w := readyRun(t)
	shipped := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	res := tick(t)
	note := "The branch has commits after the head of #1. Loam pushes them, and CI runs again"
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunShipping || res.Runs[0].Note != note {
		t.Fatalf("%+v", res)
	}
	if e := events(t, s, r.ID, "ship"); !slices.Contains(e, "Pushed the new commits to #1") {
		t.Fatalf("ship events %q", e)
	}
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if head := testutil.Git(t, r.Folder, "rev-parse", "HEAD"); testutil.Git(t, remote, "rev-parse", w.Branch) != head || head == shipped {
		t.Fatal("the new commit is not on GitHub")
	}
	// CI passes on the new head, and the run is Ready again.
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS"))
	if res := tick(t); len(res.Runs) != 1 || res.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", res)
	}
}

// A Ready run stays Ready when nothing is new: when its PR head is the head of the branch, when GitHub has commits
// that the worktree does not have, such as a push from another machine (Loam does not push over them), and when
// HEAD is on another branch.
func TestRunTickKeepsAReadyRunWithNoNewCommitsReady(t *testing.T) {
	_, r, w := readyRun(t)
	if res := tick(t); len(res.Runs) != 0 {
		t.Fatalf("%+v", res)
	}
	testutil.Git(t, r.Folder, "checkout", "-q", "-b", "try-something")
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	if res := tick(t); len(res.Runs) != 0 {
		t.Fatalf("another branch: %+v", res)
	}
	testutil.Git(t, r.Folder, "checkout", "-q", w.Branch)
	setGitHub(t, ciState(w.Branch, strings.Repeat("c", 40), "SUCCESS"))
	writeAndCommit(t, r.Folder, "more.txt", "and more\n")
	if res := tick(t); len(res.Runs) != 0 {
		t.Fatalf("a head from elsewhere: %+v", res)
	}
}

// An auto merge or a merge queue merges the PR as it is. A commit after Ready does not go into it while it waits.
func TestRunTickDoesNotPushIntoALandThatWaitsForGitHub(t *testing.T) {
	s, r, w := readyRun(t)
	if err := s.SetPendingLand(w.ID, &store.PendingLand{PR: 1, Method: "squash", Auto: true}); err != nil {
		t.Fatal(err)
	}
	shipped := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	if res := tick(t); len(res.Runs) != 0 {
		t.Fatalf("%+v", res)
	}
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != shipped {
		t.Fatal("Loam pushed into the auto merge")
	}
}

// A commit that you push by hand is on the PR, but CI did not pass on it. When its checks run, the run is Shipping
// again, and it is Ready when they pass.
func TestRunTickReadsCIAgainAfterAPushByHand(t *testing.T) {
	s, r, w := readyRun(t)
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	testutil.Git(t, r.Folder, "push", "-q", "origin", w.Branch)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, ciState(w.Branch, head, ""))
	res := tick(t)
	note := "The checks of #1 run or failed after it was ready. Loam reads CI again"
	if len(res.Runs) != 1 || res.Runs[0].State != store.RunShipping || res.Runs[0].Note != note {
		t.Fatalf("%+v", res)
	}
	if e := events(t, s, r.ID, "ship"); !slices.Contains(e, note) {
		t.Fatalf("ship events %q", e)
	}
	setGitHub(t, ciState(w.Branch, head, "SUCCESS"))
	if res := tick(t); len(res.Runs) != 1 || res.Runs[0].State != store.RunReady {
		t.Fatalf("%+v", res)
	}
}

// A PR head from another machine is not on the branch, so Loam cannot push it or read CI on it as Shipping. When its
// checks run, the run stays Ready.
func TestRunTickKeepsAReadyRunReadyWhenChecksRunOnAHeadFromElsewhere(t *testing.T) {
	s, r, w := readyRun(t)
	writeAndCommit(t, r.Folder, "elsewhere.txt", "from another machine\n")
	elsewhere := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	testutil.Git(t, r.Folder, "reset", "-q", "--hard", "HEAD~1")
	for _, head := range []string{elsewhere, strings.Repeat("c", 40)} {
		setGitHub(t, ciState(w.Branch, head, ""))
		if res := tick(t); len(res.Runs) != 0 {
			t.Fatalf("head %s: %+v", head, res)
		}
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("run %+v", got)
	}
}

// TAS-53: the desk shows the diff of a Ready run and merges the head of that diff, so the diff is the PR: it ends at
// the head that Loam pushed, not at a commit after it.
func TestRunDiffOfAReadyRunEndsAtThePushedHead(t *testing.T) {
	_, r, _ := readyRun(t)
	shipped := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	out, code := loam(t, "run", "diff", r.ID, "--json")
	var got run.DiffResult
	if code != 0 || json.Unmarshal([]byte(out), &got) != nil {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got.Head != shipped || len(got.Files) != 1 || got.Files[0].Path != "hello.txt" {
		t.Fatalf("%s", out)
	}
}

// With no origin/<branch>, such as after a fetch pruned the branch of a merged PR, the diff of a Ready run fails. It
// does not end at HEAD, which can have commits that the PR does not have.
func TestRunDiffOfAReadyRunWithNoPushedHeadFails(t *testing.T) {
	_, r, w := readyRun(t)
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	testutil.Git(t, r.Folder, "update-ref", "-d", "refs/remotes/origin/"+w.Branch)
	out, code := loam(t, "run", "diff", r.ID, "--json")
	if code == 0 || !strings.Contains(out, "could not read the pushed head of "+w.Branch) {
		t.Fatalf("exit %d: %s", code, out)
	}
}

// TAS-53: a land with the head of a commit after the PR head says that the PR does not have that commit yet. It does
// not say that the PR has new commits.
func TestRunLandWithACommitAfterThePRHeadSaysThePRDoesNotHaveIt(t *testing.T) {
	_, r, _ := readyRun(t)
	writeAndCommit(t, r.Folder, "later.txt", "one more\n")
	_, code, out := runLand(t, r.ID, "--head", testutil.Git(t, r.Folder, "rev-parse", "HEAD"))
	want := "PR #1 does not have the commit that you looked at. Look again when GitHub has it, before you merge"
	if code == 0 || !strings.Contains(out, want) {
		t.Fatalf("exit %d: %s", code, out)
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
