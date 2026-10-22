package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// landState is a made-up GitHub repo where fix-login has an open PR #15 at
// head, ready to merge. The repo allows merge and squash, and squash is the
// default.
func landState(head string) string {
	return fmt.Sprintf(`{
  "refs": ["fix-login"],
  "pulls": [{"number": 15, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/15",
    "state": "OPEN", "isDraft": false, "isCrossRepository": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
    "reviewDecision": "APPROVED", "baseRefName": "main", "headRefName": "fix-login", "headRefOid": %q,
    "commits": {"totalCount": 1}}],
  "details": {"15": {"baseRef": {"compare": {"behindBy": 0}}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]},
    "reviewThreads": {"nodes": []}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"totalCount": 2, "nodes": [
      {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true},
      {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": false,
       "checkSuite": {"workflowRun": {"databaseId": 101, "workflow": {"name": "ci"}}}}]}}}}]}}},
  "repository": {"mergeCommitAllowed": true, "squashMergeAllowed": true, "rebaseMergeAllowed": false,
    "viewerDefaultMergeMethod": "SQUASH"}
}`, head)
}

// landCLI makes a plot with the worktree fix-login, whose branch has one
// commit and is on GitHub. The fake gh has its PR #15 from state. It returns
// the store, the worktree, and the PR head.
func landCLI(t *testing.T, state func(head string) string) (*store.Store, store.Worktree, string) {
	t.Helper()
	testutil.GitEnv(t)
	repo, remote := testutil.GitRepo(t)
	s, p := linkRepoEnv(t, store.PlotInput{Repos: []store.RepoInput{{Path: repo}}})
	if _, errOut, err := lrRun(t, "", "worktree", "new", "alpha", repo, "fix-login"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	ws, err := s.ListWorktrees(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	w := ws[0]
	testutil.Git(t, w.Path, "commit", "--allow-empty", "-m", "fix the login form")
	testutil.FakeGitHub(t, remote)
	testutil.Git(t, repo, "remote", "set-url", "origin", testutil.GitHubOrigin)
	testutil.Git(t, w.Path, "push", "origin", "fix-login")
	head := testutil.Git(t, w.Path, "rev-parse", "HEAD")
	testutil.FakeGH(t, state(head))
	return s, w, head
}

// loam runs loam in process and returns stdout and the exit code.
func loam(t *testing.T, args ...string) (string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	root := NewRootCmd()
	root.SetOut(&out)
	root.SetErr(&errOut)
	code := execute(root, args, &out, &errOut)
	return out.String() + errOut.String(), code
}

// ghArgs returns the gh calls that are not GraphQL queries.
func ghArgs(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, c := range testutil.FakeGHCalls(t) {
		if !slices.Contains(c.Args, "graphql") {
			out = append(out, strings.Join(c.Args, " "))
		}
	}
	return out
}

func TestWorktreeLand(t *testing.T) {
	s, w, head := landCLI(t, landState)
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--method", "merge", "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var res worktree.LandResult
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	if !res.Merged || !res.WorktreeRemoved || !res.RemoteBranchDeleted || !res.BranchDeleted || res.Method != "merge" {
		t.Fatalf("%s", out)
	}
	want := []string{
		"pr merge 15 --repo github.com/example/widgets --merge --match-head-commit " + head,
		"api --hostname github.com repos/example/widgets/git/ref/heads/fix-login",
		"api --hostname github.com --method DELETE repos/example/widgets/git/refs/heads/fix-login",
	}
	if got := ghArgs(t); !slices.Equal(got, want) {
		t.Fatalf("gh calls\n got %q\nwant %q", got, want)
	}
	if _, err := s.GetWorktree(w.ID); err == nil {
		t.Fatal("the worktree is still there")
	}
}

func TestWorktreeLandText(t *testing.T) {
	landCLI(t, landState)
	out, code := loam(t, "worktree", "land", "alpha", "fix-login")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	for _, want := range []string{"Merged PR #15 with squash.", "Deleted the branch fix-login on GitHub.",
		"Removed the worktree app-fix-login.", "Deleted the local branch fix-login."} {
		if !strings.Contains(out, want) {
			t.Fatalf("no %q in:\n%s", want, out)
		}
	}
}

// A dry run prints the plan, and a check that blocks.
func TestWorktreeLandDryRun(t *testing.T) {
	_, w, _ := landCLI(t, landState)
	if err := os.WriteFile(filepath.Join(w.Path, "notes.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--dry-run")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	for _, want := range []string{"PR #15", "Methods: merge, squash (default squash)", "checks: passed",
		"local_changes: changed (blocks)", "Not ready to land."} {
		if !strings.Contains(out, want) {
			t.Fatalf("no %q in:\n%s", want, out)
		}
	}
	if got := ghArgs(t); len(got) != 0 {
		t.Fatalf("gh calls %q", got)
	}
}

// A check that blocks exits 16, and the details list the checks.
func TestWorktreeLandNotReadyExits16(t *testing.T) {
	_, w, _ := landCLI(t, landState)
	testutil.Git(t, w.Path, "commit", "--allow-empty", "-m", "more")
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--json")
	if code != ExitNotReady {
		t.Fatalf("exit %d: %s", code, out)
	}
	var v struct {
		Error struct {
			Kind    string `json:"kind"`
			Details struct {
				Checks []worktree.LandCheck `json:"checks"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatal(err)
	}
	want := []worktree.LandCheck{{Name: worktree.CheckUnpushedCommits, State: worktree.StateUnpushed, Blocks: true}}
	if v.Error.Kind != "not_ready" || !slices.Equal(v.Error.Details.Checks, want) {
		t.Fatalf("%s", out)
	}
	if got := ghArgs(t); len(got) != 0 {
		t.Fatalf("gh calls %q", got)
	}
}

// A dry run prints the one check of a merged PR.
func TestWorktreeLandDryRunOfAMergedPR(t *testing.T) {
	_, w, _ := landCLI(t, func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED"`, 1)
	})
	testutil.Git(t, w.Path, "commit", "--allow-empty", "-m", "more")
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--dry-run")
	if code != 0 || !strings.Contains(out, "work_after_pr: found (blocks)") || !strings.Contains(out, "Not ready to land.") {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestWorktreeLandWithNoGitHubExits17(t *testing.T) {
	landCLI(t, landState)
	t.Setenv("LOAM_GH", filepath.Join(t.TempDir(), "gh"))
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--json")
	if code != ExitGHUnavailable || !strings.Contains(out, `"kind": "gh_unavailable"`) {
		t.Fatalf("exit %d: %s", code, out)
	}
}

// --auto records the land on the worktree, and worktree list shows it.
func TestWorktreeLandAuto(t *testing.T) {
	landCLI(t, landState)
	out, code := loam(t, "worktree", "land", "alpha", "fix-login", "--auto", "--keep-remote-branch")
	if code != 0 || !strings.Contains(out, "GitHub merges PR #15 when it can") {
		t.Fatalf("exit %d: %s", code, out)
	}
	got := listJSON(t, "alpha")["fix-login"].Worktree.Land
	if want := (store.PendingLand{PR: 15, Method: "squash", Auto: true, KeepRemoteBranch: true}); got == nil || *got != want {
		t.Fatalf("%+v", got)
	}
}

func TestWorktreeLandFlags(t *testing.T) {
	landCLI(t, landState)
	for _, args := range [][]string{
		{"worktree", "land", "alpha", "fix-login", "--method", "fast"},
		{"worktree", "land", "alpha", "fix-login", "--method", "rebase"},
		{"worktree", "land", "alpha"},
	} {
		if out, code := loam(t, args...); code != ExitInvalid {
			t.Errorf("%q: exit %d: %s", args, code, out)
		}
	}
	if got := ghArgs(t); len(got) != 0 {
		t.Fatalf("gh calls %q", got)
	}
}

func TestWorktreeRerun(t *testing.T) {
	landCLI(t, landState)
	out, code := loam(t, "worktree", "rerun", "alpha", "fix-login", "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var res worktree.RerunResult
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(res.Runs, []worktree.FailedRun{{ID: 101, Started: true}}) || res.PR.Number != 15 {
		t.Fatalf("%s", out)
	}
	if got := ghArgs(t); !slices.Equal(got, []string{"run rerun 101 --failed --repo github.com/example/widgets"}) {
		t.Fatalf("%q", got)
	}
	out, code = loam(t, "worktree", "rerun", "alpha", "fix-login")
	if code != 0 || !strings.Contains(out, "Started the failed jobs of 1 run(s) again for PR #15.") {
		t.Fatalf("exit %d: %s", code, out)
	}
}

// A run that GitHub does not start again: the text says why. When no run
// starts, the exit code is 1.
func TestWorktreeRerunRefused(t *testing.T) {
	landCLI(t, func(head string) string {
		return strings.Replace(landState(head), `"refs": [`, `"rerun_refusals": {"101": "Unable to retry this workflow run"}, "refs": [`, 1)
	})
	out, code := loam(t, "worktree", "rerun", "alpha", "fix-login")
	if code != 1 || !strings.Contains(out, "could not re-run the run 101: failed to rerun: HTTP 403: Unable to retry this workflow run") {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestWorktreeUpdate(t *testing.T) {
	landCLI(t, landState)
	out, code := loam(t, "worktree", "update", "alpha", "fix-login", "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var res worktree.UpdateResult
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	if !res.Fetched || res.PR.Number != 15 {
		t.Fatalf("%s", out)
	}
	if got := ghArgs(t); !slices.Equal(got, []string{"pr update-branch 15 --repo github.com/example/widgets"}) {
		t.Fatalf("%q", got)
	}
	out, code = loam(t, "worktree", "update", "alpha", "fix-login")
	if code != 0 || !strings.Contains(out, "GitHub brought PR #15 up to date with main. Fetched fix-login.") {
		t.Fatalf("exit %d: %s", code, out)
	}
}
