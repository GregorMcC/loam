package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ticket 206: Ship. A run that passed its gate is pushed, gets a PR, and
// waits for CI. CI decides whether it is Ready, or goes back with a try.

const shipSession = "c57ef956-3136-4e86-bfde-da8facfe0523"

type tickOut struct {
	Runs     []store.Run `json:"runs"`
	Warnings []string    `json:"warnings"`
}

// shipRun gives a run with a session, whose repo is on GitHub, a passed
// gate. It returns the run, in Shipping, and its worktree. The code review
// before a push finds no issue.
func shipRun(t *testing.T, maxTries string) (*store.Store, store.Run, store.Worktree) {
	t.Helper()
	s, r := gateRun(t, maxTries)
	stopHook(t, r, "SessionStart")
	w, err := s.GetWorktree(r.WorktreeID)
	if err != nil {
		t.Fatal(err)
	}
	testutil.FakeGitHub(t, filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git"))
	testutil.Git(t, w.Repo, "remote", "set-url", "origin", testutil.GitHubOrigin)
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("gate: %d %s", code, reason)
	}
	testutil.FakeGH(t, `{}`)
	testutil.FakeClaudePrintFor(t, codeReviewSchemaText, codeReviewAnswer(`[]`))
	// The tick after a rerun reads CI at once.
	wait := run.CIRerunWait
	run.CIRerunWait = 0
	t.Cleanup(func() { run.CIRerunWait = wait })
	r, _ = s.GetRun(r.ID)
	if r.State != store.RunShipping {
		t.Fatalf("not shipping: %+v", r)
	}
	return s, r, w
}

func tick(t *testing.T) tickOut {
	t.Helper()
	out, _, err := lrRun(t, "", "run", "tick", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got tickOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got
}

// ciState is GitHub with PR #1 of the branch at head, and one check, test,
// with the conclusion. A failed check is a job of the Actions run 9001,
// whose failed log ends in FAIL: TestDrag. The repo squashes by default, and
// the PR is up to date with main, so a passed PR can merge.
func ciState(branch, head, conclusion string) string {
	rollup := map[string]string{"SUCCESS": "SUCCESS", "FAILURE": "FAILURE", "": "PENDING"}[conclusion]
	status := "COMPLETED"
	if conclusion == "" {
		status = "IN_PROGRESS"
	}
	return fmt.Sprintf(`{
  "refs": [%[1]q],
  "pulls": [{"number": 1, "title": "Say hi", "url": "https://github.com/example/widgets/pull/1", "state": "OPEN",
    "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "baseRefName": "main", "headRefName": %[1]q, "headRefOid": %[2]q,
    "commits": {"totalCount": 1}}],
  "details": {"1": {"baseRef": {"compare": {"behindBy": 0}}, "reviewThreads": {"nodes": []},
    "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": %[3]q, "contexts": {"totalCount": 1, "nodes": [
    {"__typename": "CheckRun", "name": "test", "status": %[4]q, "conclusion": %[5]q, "isRequired": true,
     "checkSuite": {"workflowRun": {"databaseId": 9001, "workflow": {"name": "ci"}}}}]}}}}]}}},
  "repository": {"mergeCommitAllowed": true, "squashMergeAllowed": true, "rebaseMergeAllowed": false,
    "viewerDefaultMergeMethod": "SQUASH"},
  "logs": {"9001": "test\tgo test\t--- FAIL: TestDrag (0.00s)\ntest\tgo test\tFAIL\n"}
}`, branch, head, rollup, status, conclusion)
}

// failCI fails the check of PR #1 on the head of the run, and ticks until
// the failure goes back to the session: the first tick runs the failed jobs
// again and counts no try (TAS-210), and the jobs fail again. It returns the
// second tick.
func failCI(t *testing.T, r store.Run, w store.Worktree) tickOut {
	t.Helper()
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "FAILURE"))
	reruns := len(ghReruns(t))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Tries != r.Tries ||
		len(ghReruns(t)) != reruns+1 {
		t.Fatalf("the first failure did not run the failed jobs again: %+v, %q", got, ghReruns(t))
	}
	return tick(t)
}

// ghReruns are the gh run rerun calls.
func ghReruns(t *testing.T) [][]string {
	var out [][]string
	for _, c := range testutil.FakeGHCalls(t) {
		if len(c.Args) > 1 && c.Args[0] == "run" && c.Args[1] == "rerun" {
			out = append(out, c.Args)
		}
	}
	return out
}

func events(t *testing.T, s *store.Store, id, kind string) []string {
	t.Helper()
	all, err := s.RunEvents(id)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range all {
		if e.Kind == kind {
			out = append(out, e.Detail)
		}
	}
	return out
}

func ghCreates(t *testing.T) [][]string {
	var out [][]string
	for _, c := range testutil.FakeGHCalls(t) {
		if len(c.Args) > 1 && c.Args[0] == "pr" && c.Args[1] == "create" {
			out = append(out, c.Args)
		}
	}
	return out
}

func TestRunTickPushesTheBranchAndOpensAPR(t *testing.T) {
	s, r, w := shipRun(t, "3")
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].PR == nil ||
		got.Runs[0].PR.Number != 1 || got.Runs[0].PR.URL != "https://github.com/example/widgets/pull/1" {
		t.Fatalf("%+v", got)
	}
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != testutil.Git(t, r.Folder, "rev-parse", "HEAD") {
		t.Fatal("the branch is not on GitHub")
	}
	creates := ghCreates(t)
	if len(creates) != 1 || !slices.Contains(creates[0], w.Branch) || !slices.Contains(creates[0], "main") ||
		!slices.Contains(creates[0], "Say hi") {
		t.Fatalf("creates %q", creates)
	}
	if e := events(t, s, r.ID, "ship"); !slices.Contains(e, "Opened #1") {
		t.Fatalf("ship events %q", e)
	}
	// GitHub does not show the new head yet: the run waits, and Loam opens
	// no second PR.
	if got := tick(t); len(got.Runs) != 0 || len(ghCreates(t)) != 1 {
		t.Fatalf("second tick %+v, %d creates", got, len(ghCreates(t)))
	}
}

func TestRunTickMakesARunReadyWhenCIPasses(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, ciState(w.Branch, head, ""))
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("CI is running: %+v", got)
	}
	setGitHub(t, ciState(w.Branch, head, "SUCCESS"))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "ci"); len(e) != 1 || e[0] != "CI passed on #1: 1 of 1 checks" {
		t.Fatalf("ci events %q", e)
	}
	// A Ready run needs nothing more from a tick.
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("tick after Ready: %+v", got)
	}
}

func TestRunTickSendsACIFailureBackToTheSessionAsATry(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	got := failCI(t, r, w)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Tries != 1 ||
		got.Runs[0].Note != "CI failed twice on #1: ci / test" {
		t.Fatalf("%+v", got)
	}
	calls := testutil.FakeClaudeCalls(t)
	n := len(calls)
	if n < 2 || !slices.Equal(calls[n-2], []string{"stop", shipSession[:8]}) || len(calls[n-1]) < 4 ||
		!slices.Equal(calls[n-1][:3], []string{"--bg", "--resume", shipSession}) || !slices.Contains(calls[n-1], "--settings") {
		t.Fatalf("claude calls %q", calls)
	}
	prompt := calls[n-1][len(calls[n-1])-1]
	for _, want := range []string{"CI failed twice on #1", "try 1 of 3", "## ci / test", "--- FAIL: TestDrag", "commit",
		"Do not change a test outside the goal of the run"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	// The fix comes back through the gate, and the next tick pushes it to
	// the same PR.
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatal("the gate did not pass the fix")
	}
	tick(t)
	if len(ghCreates(t)) != 1 {
		t.Fatalf("a second PR: %q", ghCreates(t))
	}
	remote := filepath.Join(filepath.Dir(filepath.Dir(w.Repo)), "remote.git")
	if testutil.Git(t, remote, "rev-parse", w.Branch) != testutil.Git(t, r.Folder, "rev-parse", "HEAD") {
		t.Fatal("the fix is not on GitHub")
	}
	if e := events(t, s, r.ID, "ship"); !slices.Contains(e, "Pushed the fix to #1") {
		t.Fatalf("ship events %q", e)
	}
}

func TestRunTickStopsARunWhenCIUsesTheLastTry(t *testing.T) {
	_, r, w := shipRun(t, "1")
	tick(t)
	got := failCI(t, r, w)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped || got.Runs[0].Note != "CI failed twice on #1 after 1 try: ci / test" {
		t.Fatalf("%+v", got)
	}
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "--resume") {
			t.Fatalf("a stopped run got a prompt: %q", c)
		}
	}
}

// TAS-210: a flaky job that the run did not touch costs no try. Loam runs
// the failed jobs of a head again once, and a second failure on that head
// goes back to the session. A new head gets its own rerun.
func TestRunTickRerunsTheFailedJobsOnceForEachHead(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, ciState(w.Branch, head, "FAILURE"))
	rerunNote := "CI failed on #1: ci / test. Loam runs the failed jobs again (run 9001)"
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Tries != 0 || got.Runs[0].Note != rerunNote {
		t.Fatalf("first failure %+v", got)
	}
	if reruns := ghReruns(t); len(reruns) != 1 ||
		!slices.Equal(reruns[0], []string{"run", "rerun", "9001", "--failed", "--repo", "github.com/example/widgets"}) {
		t.Fatalf("reruns %q", reruns)
	}
	if e := events(t, s, r.ID, "ci"); !slices.Equal(e, []string{rerunNote}) {
		t.Fatalf("ci events %q", e)
	}
	if e := events(t, s, r.ID, "try"); len(e) != 0 {
		t.Fatalf("try events %q", e)
	}
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "--resume") {
			t.Fatalf("a rerun sent the failure to the session: %q", c)
		}
	}

	// The jobs fail again on the same head: the failure goes back as a try,
	// and Loam does not run them a second time.
	setGitHub(t, ciState(w.Branch, head, "FAILURE"))
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Tries != 1 ||
		got.Runs[0].Note != "CI failed twice on #1: ci / test" || len(ghReruns(t)) != 1 {
		t.Fatalf("second failure %+v, reruns %q", got, ghReruns(t))
	}
	if prompt := lastPrompt(t); !strings.HasPrefix(prompt, "CI failed twice on #1 (try 1 of 3): Loam ran the failed jobs again") {
		t.Fatalf("prompt %s", prompt)
	}
	if e := events(t, s, r.ID, "try"); !slices.Equal(e, []string{"CI failed twice on #1: ci / test"}) {
		t.Fatalf("try events %q", e)
	}

	// The fix is a new head, and its first failure runs the jobs again.
	writeAndCommit(t, r.Folder, "fix.txt", "fixed\n")
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatal("the gate did not pass the fix")
	}
	tick(t)
	fix := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	setGitHub(t, ciState(w.Branch, fix, "FAILURE"))
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].Tries != 1 || len(ghReruns(t)) != 2 {
		t.Fatalf("failure of the fix %+v, reruns %q", got, ghReruns(t))
	}
}

// GitHub can show the failed jobs of the first attempt for a moment after
// the rerun, so a failure soon after it waits.
func TestRunTickWaitsForTheRerunBeforeTheSecondFailure(t *testing.T) {
	_, r, w := shipRun(t, "3")
	run.CIRerunWait = time.Hour
	tick(t)
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "FAILURE"))
	tick(t)
	if got := tick(t); len(got.Runs) != 0 || len(ghReruns(t)) != 1 {
		t.Fatalf("the tick after the rerun %+v, reruns %q", got, ghReruns(t))
	}
}

// A rerun that GitHub refuses, such as of a run that is gone, sends the
// failure back to the session as before, and it counts a try.
func TestRunTickSendsACIFailureBackWhenTheRerunFails(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	state := ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "FAILURE")
	setGitHub(t, strings.Replace(state, `"logs":`, `"rerun_refusals": {"9001": "Not Found"}, "logs":`, 1))
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || got.Runs[0].Tries != 1 ||
		got.Runs[0].Note != "CI failed on #1: ci / test" {
		t.Fatalf("%+v", got)
	}
	e := events(t, s, r.ID, "ci")
	if len(e) != 2 || !strings.HasPrefix(e[0], "CI failed on #1: ci / test. Loam could not run the failed jobs again: ") ||
		!strings.Contains(e[0], "Not Found") || e[1] != "CI failed on #1: ci / test" {
		t.Fatalf("ci events %q", e)
	}
	if prompt := lastPrompt(t); !strings.HasPrefix(prompt, "CI failed on #1 (try 1 of 3).") {
		t.Fatalf("prompt %s", prompt)
	}
}

func TestRunTickAttachesThePRToTheLinearIssue(t *testing.T) {
	s, r, _ := shipRun(t, "3")
	f := testutil.FakeLinear(t)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Source = &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	tick(t)
	if e := events(t, s, r.ID, "linear"); !slices.Contains(e, "Attached #1 to ENG-523") {
		t.Fatalf("linear events %q", e)
	}
	if v := f.Calls()[0].Variables; v["id"] != "ENG-523" || v["url"] != "https://github.com/example/widgets/pull/1" {
		t.Fatalf("attach vars %+v", v)
	}
}

func TestRunTickMakesARunReadyWhenItsPRHasNoCI(t *testing.T) {
	defer func(wait time.Duration) { run.NoCIWait = wait }(run.NoCIWait)
	_, r, w := shipRun(t, "3")
	tick(t)
	// GitHub gives no check rollup to a commit with no checks.
	setGitHub(t, fmt.Sprintf(`{"refs": [%[1]q], "pulls": [{"number": 1, "url": "https://github.com/example/widgets/pull/1",
  "state": "OPEN", "baseRefName": "main", "headRefName": %[1]q, "headRefOid": %[2]q}],
  "details": {"1": {"commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]}}}}`,
		w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD")))
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("CI may not have started yet: %+v", got)
	}
	run.NoCIWait = 0
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunReady || got.Runs[0].Note != "No CI ran on #1" {
		t.Fatalf("%+v", got)
	}
}

// setGitHub writes the state of the fake gh.
func setGitHub(t *testing.T, state string) {
	t.Helper()
	if err := os.WriteFile(os.Getenv("LOAM_FAKE_GH_STATE"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
}
