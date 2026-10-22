package worktree_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// landState is a made-up GitHub repo where fix-login has an open PR #15 at
// head: one required check passed, and a reviewer approved. The repo allows
// merge and squash, and squash is the default.
func landState(head string) string {
	return fmt.Sprintf(`{
  "refs": ["fix-login"],
  "pulls": [{"number": 15, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/15",
    "state": "OPEN", "isDraft": false, "isCrossRepository": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
    "reviewDecision": "APPROVED", "baseRefName": "main", "headRefName": "fix-login", "headRefOid": %q,
    "commits": {"totalCount": 1}}],
  "details": {"15": {"baseRef": {"compare": {"behindBy": 0}}, "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}]},
    "reviewThreads": {"nodes": []}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {"totalCount": 1, "nodes": [
      {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true}]}}}}]}}},
  "repository": {"mergeCommitAllowed": true, "squashMergeAllowed": true, "rebaseMergeAllowed": false,
    "viewerDefaultMergeMethod": "SQUASH"}
}`, head)
}

// landing makes the worktree fix-login with one commit, and points origin
// at GitHub. The branch is on GitHub, and the fake gh has its PR #15, ready
// to merge, from state. It returns the worktree and the PR head.
func (e *env) landing(state func(head string) string) (store.Worktree, string) {
	e.t.Helper()
	w := e.create("fix-login", "").Worktree
	commit(e.t, w.Path, "login.txt", "fixed\n")
	testutil.FakeGitHub(e.t, e.remote)
	testutil.Git(e.t, e.repo, "remote", "set-url", "origin", testutil.GitHubOrigin)
	testutil.Git(e.t, w.Path, "push", "origin", "fix-login")
	head := testutil.Git(e.t, w.Path, "rev-parse", "HEAD")
	testutil.FakeGH(e.t, state(head))
	return w, head
}

func (e *env) land(o worktree.LandOptions) (*worktree.LandResult, error) {
	e.t.Helper()
	return worktree.Land(context.Background(), e.s, e.plot.ID, "fix-login", o)
}

// ghCommands returns the gh calls, one string each. A GraphQL query is
// "graphql".
func ghCommands(t *testing.T) []string {
	t.Helper()
	var out []string
	for _, c := range testutil.FakeGHCalls(t) {
		if slices.Contains(c.Args, "graphql") {
			out = append(out, "graphql")
			continue
		}
		out = append(out, strings.Join(c.Args, " "))
	}
	return out
}

// merges reports whether gh got a merge call.
func merges(t *testing.T) bool {
	t.Helper()
	return slices.ContainsFunc(ghCommands(t), func(c string) bool { return strings.HasPrefix(c, "pr merge") })
}

func (e *env) branchExists(name string) bool {
	e.t.Helper()
	return testutil.Git(e.t, e.repo, "branch", "--list", name) != ""
}

const (
	getRef    = "api --hostname github.com repos/example/widgets/git/ref/heads/fix-login"
	deleteRef = "api --hostname github.com --method DELETE repos/example/widgets/git/refs/heads/fix-login"
)

// Land refreshes the PR, reads the merge settings, merges with the head that
// it checked, and asks GitHub again. Then it deletes the branch on GitHub,
// removes the worktree, and deletes the local branch: its tip is the head of
// the merged PR.
func TestLandMergesDeletesTheRemoteBranchAndRemovesTheWorktree(t *testing.T) {
	e := setup(t)
	w, head := e.landing(landState)
	res, err := e.land(worktree.LandOptions{Method: github.MethodMerge})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"graphql", "graphql", "graphql",
		"pr merge 15 --repo github.com/example/widgets --merge --match-head-commit " + head,
		"graphql", getRef, deleteRef}
	if got := ghCommands(t); !slices.Equal(got, want) {
		t.Fatalf("gh calls\n got %q\nwant %q", got, want)
	}
	if !res.Merged || res.MergeLater || !res.RemoteBranchDeleted || !res.WorktreeRemoved || !res.BranchDeleted || !res.Ready || res.DryRun {
		t.Fatalf("%+v", res)
	}
	if res.PR == nil || res.PR.Number != 15 || res.PR.State != "OPEN" || res.Stage != worktree.StageReadyToMerge ||
		res.Method != github.MethodMerge || res.DefaultMethod != github.MethodSquash ||
		!slices.Equal(res.Methods, []github.MergeMethod{github.MethodMerge, github.MethodSquash}) || res.MergeQueue {
		t.Fatalf("%+v", res)
	}
	if len(res.Checks) != len(worktree.LandCheckNames) || slices.ContainsFunc(res.Checks, func(c worktree.LandCheck) bool { return c.Blocks }) {
		t.Fatalf("checks %+v", res.Checks)
	}
	if _, err := os.Stat(w.Path); !os.IsNotExist(err) {
		t.Fatal("the folder is still there")
	}
	if _, err := e.s.GetWorktree(w.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("the record is still there")
	}
	// git branch -d refuses: the commit is not on main. The PR merged it.
	if e.branchExists("fix-login") {
		t.Fatal("the local branch is still there")
	}
}

func TestLandMethods(t *testing.T) {
	e := setup(t)
	_, head := e.landing(landState)
	// A method that the repo does not allow.
	if _, err := e.land(worktree.LandOptions{Method: github.MethodRebase}); !errors.Is(err, store.ErrInvalid) ||
		!strings.Contains(err.Error(), "merge, squash") {
		t.Fatalf("%v", err)
	}
	// A method that GitHub does not have, before any call.
	n := len(testutil.FakeGHCalls(t))
	if _, err := e.land(worktree.LandOptions{Method: "fast"}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("%v", err)
	}
	if merges(t) || len(testutil.FakeGHCalls(t)) != n {
		t.Fatalf("%q", ghCommands(t))
	}
	// No method: the default of the repo.
	res, err := e.land(worktree.LandOptions{KeepWorktree: true})
	if err != nil || res.Method != github.MethodSquash {
		t.Fatalf("%+v %v", res, err)
	}
	if !slices.Contains(ghCommands(t), "pr merge 15 --repo github.com/example/widgets --squash --match-head-commit "+head) {
		t.Fatalf("%q", ghCommands(t))
	}
}

// Each check that blocks a land stops it before the merge. The error lists
// the checks that block.
func TestLandStopsAtEachBlockingCheck(t *testing.T) {
	for _, c := range []struct {
		check worktree.CheckName
		state worktree.CheckState
		from  string // text in landState
		to    string
		local func(t *testing.T, w store.Worktree)
	}{
		{check: worktree.CheckChecks, state: worktree.StateFailed, from: `"conclusion": "SUCCESS"`, to: `"conclusion": "FAILURE"`},
		{check: worktree.CheckReview, state: worktree.StateChangesRequested, from: `"reviewDecision": "APPROVED"`, to: `"reviewDecision": "CHANGES_REQUESTED"`},
		{check: worktree.CheckConflicts, state: worktree.StateConflicting, from: `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`,
			to: `"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"`},
		// GitHub gives BEHIND only when the base branch needs the head up to date.
		{check: worktree.CheckBehindBase, state: worktree.StateBehind, from: `"mergeStateStatus": "CLEAN"`, to: `"mergeStateStatus": "BEHIND"`},
		{check: worktree.CheckGitHub, state: worktree.StateBlocked, from: `"mergeStateStatus": "CLEAN"`, to: `"mergeStateStatus": "BLOCKED"`},
		{check: worktree.CheckLocalChanges, state: worktree.StateChanged, local: func(t *testing.T, w store.Worktree) {
			os.WriteFile(filepath.Join(w.Path, "notes.txt"), []byte("n\n"), 0o644)
		}},
		{check: worktree.CheckUnpushedCommits, state: worktree.StateUnpushed, local: func(t *testing.T, w store.Worktree) {
			commit(t, w.Path, "more.txt", "m\n")
		}},
	} {
		t.Run(string(c.check), func(t *testing.T) {
			e := setup(t)
			w, _ := e.landing(func(head string) string {
				s := landState(head)
				if c.from != "" {
					if !strings.Contains(s, c.from) {
						t.Fatalf("the state has no %s", c.from)
					}
					s = strings.Replace(s, c.from, c.to, 1)
				}
				return s
			})
			if c.local != nil {
				c.local(t, w)
			}
			_, err := e.land(worktree.LandOptions{})
			var nr *worktree.NotReadyError
			if !errors.Is(err, worktree.ErrNotReady) || !errors.As(err, &nr) {
				t.Fatalf("%v", err)
			}
			want := []worktree.LandCheck{{Name: c.check, State: c.state, Blocks: true}}
			if !slices.Equal(nr.Checks, want) {
				t.Fatalf("got %+v, want %+v", nr.Checks, want)
			}
			if merges(t) {
				t.Fatalf("gh merged: %q", ghCommands(t))
			}
			if _, err := e.s.GetWorktree(w.ID); err != nil {
				t.Fatal("the worktree is gone")
			}
			// A dry run reports the same check, and does not fail.
			res, err := e.land(worktree.LandOptions{DryRun: true})
			if err != nil || res.Ready || !slices.Contains(res.Checks, want[0]) {
				t.Fatalf("dry run: %+v %v", res, err)
			}
		})
	}
}

// While GitHub checks again whether the PR can merge, the stage rule keeps
// the last stage that needs that check. The land checks follow the stage, so
// a land never goes ahead on a row that shows Conflicts, Behind base, or
// Blocked.
func TestLandChecksFollowTheKeptStage(t *testing.T) {
	for _, c := range []struct {
		mergeState string
		stage      worktree.Stage
		want       worktree.LandCheck
	}{
		{"DIRTY", worktree.StageConflicts, worktree.LandCheck{Name: worktree.CheckConflicts, State: worktree.StateConflicting, Blocks: true}},
		{"BEHIND", worktree.StageBehindBase, worktree.LandCheck{Name: worktree.CheckBehindBase, State: worktree.StateBehind, Blocks: true}},
		{"BLOCKED", worktree.StageBlocked, worktree.LandCheck{Name: worktree.CheckGitHub, State: worktree.StateBlocked, Blocks: true}},
	} {
		t.Run(c.mergeState, func(t *testing.T) {
			e := setup(t)
			w, head := e.landing(func(head string) string {
				return strings.Replace(landState(head), `"mergeStateStatus": "CLEAN"`, `"mergeStateStatus": "`+c.mergeState+`"`, 1)
			})
			if err := worktree.RefreshPRs(context.Background(), e.s, []store.Worktree{w}); err != nil {
				t.Fatal(err)
			}
			checking := strings.Replace(landState(head), `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`,
				`"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"`, 1)
			if err := os.WriteFile(os.Getenv("LOAM_FAKE_GH_STATE"), []byte(checking), 0o644); err != nil {
				t.Fatal(err)
			}
			res, err := e.land(worktree.LandOptions{DryRun: true})
			if err != nil || res.Stage != c.stage || res.Ready || !slices.Contains(res.Checks, c.want) {
				t.Fatalf("%+v %v", res, err)
			}
			_, err = e.land(worktree.LandOptions{})
			var nr *worktree.NotReadyError
			if !errors.As(err, &nr) || !slices.Equal(nr.Checks, []worktree.LandCheck{c.want}) {
				t.Fatalf("%v", err)
			}
			if merges(t) {
				t.Fatalf("gh merged: %q", ghCommands(t))
			}
		})
	}
}

// The Blocked stage blocks a direct merge, not an auto merge: GitHub waits
// until it can merge. The land records its options and keeps the worktree.
func TestLandAutoRecordsTheOptionsAndKeepsTheWorktree(t *testing.T) {
	e := setup(t)
	w, head := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"mergeStateStatus": "CLEAN"`, `"mergeStateStatus": "BLOCKED"`, 1)
	})
	res, err := e.land(worktree.LandOptions{Auto: true, KeepRemoteBranch: true})
	if err != nil {
		t.Fatal(err)
	}
	if res.Merged || !res.MergeLater || !res.Auto || res.WorktreeRemoved || res.RemoteBranchDeleted || !res.Ready {
		t.Fatalf("%+v", res)
	}
	want := []string{"graphql", "graphql", "graphql",
		"pr merge 15 --repo github.com/example/widgets --squash --auto --match-head-commit " + head, "graphql", "graphql"}
	if got := ghCommands(t); !slices.Equal(got, want) {
		t.Fatalf("gh calls\n got %q\nwant %q", got, want)
	}
	got, err := e.s.GetWorktree(w.ID)
	if err != nil {
		t.Fatal(err)
	}
	wantLand := store.PendingLand{PR: 15, Method: "squash", Auto: true, KeepRemoteBranch: true}
	if got.Land == nil || *got.Land != wantLand || res.Worktree.Land == nil || *res.Worktree.Land != wantLand {
		t.Fatalf("%+v %+v", got.Land, res.Worktree.Land)
	}
	if _, err := os.Stat(w.Path); err != nil || !e.branchExists("fix-login") {
		t.Fatal("the worktree is gone")
	}
}

// A base branch with a merge queue: land adds the PR to the queue, with no
// method. The queue merges later.
func TestLandAddsThePRToTheMergeQueue(t *testing.T) {
	e := setup(t)
	w, head := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"refs": [`, `"merge_queue": true, "refs": [`, 1)
	})
	res, err := e.land(worktree.LandOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !res.MergeQueue || res.Method != "" || res.Merged || !res.MergeLater || res.WorktreeRemoved {
		t.Fatalf("%+v", res)
	}
	if !slices.Contains(ghCommands(t), "pr merge 15 --repo github.com/example/widgets --match-head-commit "+head) {
		t.Fatalf("%q", ghCommands(t))
	}
	got, _ := e.s.GetWorktree(w.ID)
	if wantLand := (store.PendingLand{PR: 15, MergeQueue: true}); got.Land == nil || *got.Land != wantLand {
		t.Fatalf("%+v", got.Land)
	}
}

// A dry run asks GitHub, and changes nothing: no merge, no delete, no
// removal, and no recorded land.
func TestLandDryRunChangesNothing(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(landState)
	res, err := e.land(worktree.LandOptions{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := ghCommands(t); !slices.Equal(got, []string{"graphql", "graphql", "graphql"}) {
		t.Fatalf("%q", got)
	}
	if !res.DryRun || !res.Ready || res.Merged || res.MergeLater || res.WorktreeRemoved || res.Method != github.MethodSquash {
		t.Fatalf("%+v", res)
	}
	var names []worktree.CheckName
	for _, c := range res.Checks {
		names = append(names, c.Name)
	}
	if !slices.Equal(names, worktree.LandCheckNames) {
		t.Fatalf("%v", names)
	}
	got, err := e.s.GetWorktree(w.ID)
	if err != nil || got.Land != nil {
		t.Fatalf("%+v %v", got, err)
	}
}

// A check that does not block still shows its state in the plan.
func TestLandDryRunStatesThatDoNotBlock(t *testing.T) {
	for _, c := range []struct {
		name     string
		from, to string
		want     []worktree.LandCheck
	}{
		{"behind, not required", `"behindBy": 0`, `"behindBy": 3`,
			[]worktree.LandCheck{{Name: worktree.CheckBehindBase, State: worktree.StateBehind}}},
		{"checks running", `"state": "SUCCESS", "contexts": {"totalCount": 1, "nodes": [
      {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS"`,
			`"state": "PENDING", "contexts": {"totalCount": 1, "nodes": [
      {"__typename": "CheckRun", "name": "test", "status": "IN_PROGRESS", "conclusion": null`,
			[]worktree.LandCheck{{Name: worktree.CheckChecks, State: worktree.StateRunning}}},
		{"review required", `"reviewDecision": "APPROVED"`, `"reviewDecision": "REVIEW_REQUIRED"`,
			[]worktree.LandCheck{{Name: worktree.CheckReview, State: worktree.StateRequired}}},
		{"GitHub still checks", `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`, `"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"`,
			[]worktree.LandCheck{{Name: worktree.CheckConflicts, State: worktree.StateChecking},
				{Name: worktree.CheckGitHub, State: worktree.StateChecking}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			e := setup(t)
			e.landing(func(head string) string {
				s := landState(head)
				if !strings.Contains(s, c.from) {
					t.Fatalf("the state has no %s", c.from)
				}
				return strings.Replace(s, c.from, c.to, 1)
			})
			res, err := e.land(worktree.LandOptions{DryRun: true})
			if err != nil || !res.Ready {
				t.Fatalf("%+v %v", res, err)
			}
			for _, w := range c.want {
				if !slices.Contains(res.Checks, w) {
					t.Fatalf("no %+v in %+v", w, res.Checks)
				}
			}
		})
	}
}

// Land needs gh and a GitHub remote. Without them, it fails with
// ErrGHUnavailable.
func TestLandNeedsGH(t *testing.T) {
	for name, fail := range map[string]func(t *testing.T, e *env){
		"gh missing":    func(t *testing.T, e *env) { t.Setenv("LOAM_GH", filepath.Join(t.TempDir(), "gh")) },
		"gh signed out": func(t *testing.T, e *env) { t.Setenv("LOAM_FAKE_GH_FAIL", "signed_out") },
		"no GitHub remote": func(t *testing.T, e *env) {
			testutil.Git(t, e.repo, "remote", "set-url", "origin", e.remote)
		},
	} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			e.landing(landState)
			fail(t, e)
			if _, err := e.land(worktree.LandOptions{DryRun: true}); !errors.Is(err, worktree.ErrGHUnavailable) {
				t.Fatalf("%v", err)
			}
			if merges(t) {
				t.Fatal("gh merged")
			}
		})
	}
}

// A land that refreshes with no answer from GitHub stops: Loam never acts on
// an old state.
func TestLandStopsWhenGitHubDoesNotAnswer(t *testing.T) {
	e := setup(t)
	e.landing(landState)
	t.Setenv("LOAM_FAKE_GH_FAIL", "offline")
	_, err := e.land(worktree.LandOptions{})
	if !errors.Is(err, github.ErrOffline) || errors.Is(err, worktree.ErrGHUnavailable) || merges(t) {
		t.Fatalf("%v", err)
	}
}

// Land removes the worktree right after the merge, so it refuses an open
// pane before the merge. --keep-worktree merges with the pane open.
func TestLandRefusesWhilePanesAreOpen(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(landState)
	if _, err := e.land(worktree.LandOptions{OpenPanes: []string{w.Path}}); !errors.Is(err, worktree.ErrPanesOpen) ||
		!strings.Contains(err.Error(), "--keep-worktree") {
		t.Fatalf("%v", err)
	}
	if merges(t) {
		t.Fatal("gh merged")
	}
	res, err := e.land(worktree.LandOptions{OpenPanes: []string{w.Path}, KeepWorktree: true})
	if err != nil || !res.Merged || res.WorktreeRemoved || !res.RemoteBranchDeleted {
		t.Fatalf("%+v %v", res, err)
	}
	if _, err := os.Stat(w.Path); err != nil {
		t.Fatal("the folder is gone")
	}
}

// After a merge on GitHub, land does what comes after the merge: it deletes
// the branch on GitHub and removes the worktree. It clears a land that
// waited for GitHub.
func TestLandAfterAMergeOnGitHub(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED", "mergedAt": "2026-01-01T09:00:00Z"`, 1)
	})
	if err := e.s.SetPendingLand(w.ID, &store.PendingLand{PR: 15, Method: "squash", Auto: true, KeepWorktree: true}); err != nil {
		t.Fatal(err)
	}
	res, err := e.land(worktree.LandOptions{KeepWorktree: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := ghCommands(t); !slices.Equal(got, []string{"graphql", getRef, deleteRef}) {
		t.Fatalf("%q", got)
	}
	if !res.Merged || res.PR.State != "MERGED" || len(res.Checks) != 0 || !res.Ready || !res.RemoteBranchDeleted || res.WorktreeRemoved {
		t.Fatalf("%+v", res)
	}
	if got, _ := e.s.GetWorktree(w.ID); got.Land != nil || res.Worktree.Land != nil {
		t.Fatalf("the pending land stays: %+v", got.Land)
	}

	res, err = e.land(worktree.LandOptions{})
	if err != nil || !res.WorktreeRemoved || !res.BranchDeleted {
		t.Fatalf("%+v %v", res, err)
	}
}

// After a merge, a land waits for GitHub no more. It clears the land that the
// worktree records, also when the worktree stays because it has work that
// is not in the PR. The note says what to do, in words that fit a land.
func TestLandAfterAMergeClearsThePendingLandWhenTheWorktreeStays(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED", "mergedAt": "2026-01-01T09:00:00Z"`, 1)
	})
	if err := e.s.SetPendingLand(w.ID, &store.PendingLand{PR: 15, Method: "squash", Auto: true}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(w.Path, "notes.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, err := e.land(worktree.LandOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := "Kept the worktree app-fix-login: it has 1 file(s) with uncommitted changes. Save the work, then remove the worktree with loam worktree rm."
	if res.WorktreeRemoved || res.WorktreeNote != want || !res.RemoteBranchDeleted {
		t.Fatalf("%+v", res)
	}
	if got, _ := e.s.GetWorktree(w.ID); got.Land != nil || res.Worktree.Land != nil {
		t.Fatalf("the pending land stays: %+v", got.Land)
	}
}

// GitHub took a direct merge. When Loam cannot read the PR again, or the PR
// does not show the merge yet, the land says so, records its options, and
// keeps the worktree. A land again finishes it.
func TestLandAfterADirectMergeThatLoamCannotSee(t *testing.T) {
	for name, c := range map[string]struct {
		state func(head string) string
		fail  string
		note  string
	}{
		"the refresh fails": {state: landState, fail: "offline",
			note: "GitHub took the land of PR #15, but Loam could not read the PR again"},
		"the PR is not merged yet": {state: func(head string) string {
			return strings.Replace(landState(head), `"refs": [`, `"merge_lag": true, "refs": [`, 1)
		}, note: "GitHub merged PR #15, but the PR does not show the merge yet"},
	} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			w, _ := e.landing(c.state)
			if c.fail != "" {
				t.Setenv("LOAM_FAKE_GH_FAIL", c.fail)
				t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "5") // the refresh after the merge
			}
			res, err := e.land(worktree.LandOptions{})
			if err != nil {
				t.Fatal(err)
			}
			if res.Merged || !res.MergeLater || !strings.HasPrefix(res.MergeNote, c.note) ||
				!strings.HasSuffix(res.MergeNote, "Run loam worktree land again to finish it.") || res.RemoteBranchDeleted || res.WorktreeRemoved {
				t.Fatalf("%+v", res)
			}
			got, err := e.s.GetWorktree(w.ID)
			if want := (store.PendingLand{PR: 15, Method: "squash"}); err != nil || got.Land == nil || *got.Land != want {
				t.Fatalf("%+v %v", got.Land, err)
			}
		})
	}
}

// GitHub can refuse the delete of the branch. The land keeps going, and the
// note says why the branch stays.
func TestLandNotesABranchThatGitHubDoesNotDelete(t *testing.T) {
	e := setup(t)
	e.landing(landState)
	t.Setenv("LOAM_FAKE_GH_FAIL", "forbidden")
	t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "7") // the delete, after the read of the branch
	res, err := e.land(worktree.LandOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := "Kept the branch fix-login on GitHub: could not delete the branch: Resource not accessible by personal access token (HTTP 403)"
	if !res.Merged || res.RemoteBranchDeleted || res.RemoteBranchNote != want || !res.WorktreeRemoved {
		t.Fatalf("%+v", res)
	}
}

// A branch on GitHub with commits after the PR head stays: they are not in
// the PR. The worktree still goes.
func TestLandKeepsARemoteBranchWithNewCommits(t *testing.T) {
	e := setup(t)
	e.landing(func(head string) string {
		return strings.Replace(landState(head), `"refs": [`, `"heads": {"fix-login": "5555555555555555555555555555555555555555"}, "refs": [`, 1)
	})
	res, err := e.land(worktree.LandOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !res.Merged || res.RemoteBranchDeleted || !strings.Contains(res.RemoteBranchNote, "fix-login") || !res.WorktreeRemoved {
		t.Fatalf("%+v", res)
	}
	if slices.Contains(ghCommands(t), deleteRef) {
		t.Fatal("gh deleted the branch")
	}
}

func TestLandKeepFlags(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(landState)
	res, err := e.land(worktree.LandOptions{KeepWorktree: true, KeepRemoteBranch: true})
	if err != nil || !res.Merged || res.RemoteBranchDeleted || res.WorktreeRemoved || res.BranchDeleted {
		t.Fatalf("%+v %v", res, err)
	}
	if slices.Contains(ghCommands(t), getRef) {
		t.Fatalf("%q", ghCommands(t))
	}
	if _, err := os.Stat(w.Path); err != nil || !e.branchExists("fix-login") {
		t.Fatal("the worktree is gone")
	}
}

// Land merges only an open PR that is not in the merge queue, at the head
// commit that it checked.
func TestLandRefusesAPRThatItCannotMerge(t *testing.T) {
	for name, edit := range map[string]func(string) string{
		"in the merge queue": func(s string) string {
			return strings.Replace(s, `"isDraft": false`, `"isDraft": false, "isInMergeQueue": true, "mergeQueueEntry": {"position": 1}`, 1)
		},
		"no head commit": func(s string) string {
			return strings.Replace(s, `"headRefOid": "`, `"headRefOid": "x`, 1)
		},
		"no PR": func(s string) string {
			return strings.Replace(s, `"headRefName": "fix-login"`, `"headRefName": "other"`, 1)
		},
		"closed": func(s string) string {
			return strings.Replace(s, `"state": "OPEN"`, `"state": "CLOSED", "closedAt": "2026-01-01T09:00:00Z"`, 1)
		},
	} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			e.landing(func(head string) string { return edit(landState(head)) })
			if _, err := e.land(worktree.LandOptions{}); err == nil || errors.Is(err, worktree.ErrNotReady) || merges(t) {
				t.Fatalf("%v", err)
			}
		})
	}
}

// GitHub refuses the merge: its message comes back, and nothing after the
// merge runs.
func TestLandReturnsTheMessageOfARefusedMerge(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(landState)
	t.Setenv("LOAM_FAKE_GH_FAIL", "not_mergeable")
	t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "4") // two refresh queries, the settings, then the merge
	_, err := e.land(worktree.LandOptions{})
	if err == nil || !strings.Contains(err.Error(), "could not merge PR #15: Pull request example/widgets#15 is not mergeable") {
		t.Fatalf("%v", err)
	}
	if got := ghCommands(t); len(got) != 4 || !strings.HasPrefix(got[3], "pr merge") {
		t.Fatalf("%q", got)
	}
	if got, err := e.s.GetWorktree(w.ID); err != nil || got.Land != nil {
		t.Fatalf("%+v %v", got, err)
	}
}

// Remove deletes the local branch with -D when the PR cache says that the
// PR merged, and the branch tip is the PR head. A squash merge leaves the
// commits off main, so -d refuses.
func TestRemoveDeletesTheBranchOfAMergedPR(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED"`, 1)
	})
	if err := worktree.RefreshPRs(context.Background(), e.s, []store.Worktree{w}); err != nil {
		t.Fatal(err)
	}
	res, err := worktree.Remove(e.s, e.plot.ID, "fix-login", worktree.RemoveOptions{})
	if err != nil || !res.BranchDeleted || res.BranchNote != "" || e.branchExists("fix-login") {
		t.Fatalf("%+v %v", res, err)
	}
}

// A new commit after the PR head is not in the PR: Remove keeps -d, which
// refuses, and the note.
func TestRemoveKeepsTheBranchWithANewCommitAfterAMerge(t *testing.T) {
	e := setup(t)
	w, _ := e.landing(func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED"`, 1)
	})
	if err := worktree.RefreshPRs(context.Background(), e.s, []store.Worktree{w}); err != nil {
		t.Fatal(err)
	}
	commit(t, w.Path, "more.txt", "m\n")
	testutil.Git(t, w.Path, "push", "origin", "fix-login")
	res, err := worktree.Remove(e.s, e.plot.ID, "fix-login", worktree.RemoveOptions{})
	if err != nil || res.BranchDeleted || !strings.Contains(res.BranchNote, "git branch -D") || !e.branchExists("fix-login") {
		t.Fatalf("%+v %v", res, err)
	}
}

// failedRuns is landState with failed checks: two jobs of run 101, one job
// of run 102, and a status from another CI, which has no run.
func failedRuns(head string) string {
	return strings.Replace(landState(head),
		`{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true}`,
		`{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": true,
		  "checkSuite": {"workflowRun": {"databaseId": 101, "workflow": {"name": "ci"}}}},
		 {"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "TIMED_OUT", "isRequired": false,
		  "checkSuite": {"workflowRun": {"databaseId": 101, "workflow": {"name": "ci"}}}},
		 {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": false,
		  "checkSuite": {"workflowRun": {"databaseId": 102, "workflow": {"name": "docs"}}}},
		 {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR", "isRequired": false}`, 1)
}

func TestRerunRunsEachFailedRunAgain(t *testing.T) {
	e := setup(t)
	e.landing(failedRuns)
	res, err := worktree.Rerun(context.Background(), e.s, e.plot.ID, "", "fix-login")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(res.Runs, []int64{101, 102}) || res.PR.Number != 15 {
		t.Fatalf("%+v", res)
	}
	want := []string{"graphql", "graphql",
		"run rerun 101 --failed --repo github.com/example/widgets", "run rerun 102 --failed --repo github.com/example/widgets"}
	if got := ghCommands(t); !slices.Equal(got, want) {
		t.Fatalf("gh calls\n got %q\nwant %q", got, want)
	}
}

func TestRerunWithNoFailedRun(t *testing.T) {
	e := setup(t)
	e.landing(landState)
	res, err := worktree.Rerun(context.Background(), e.s, e.plot.ID, "", "fix-login")
	if err != nil || res.Runs == nil || len(res.Runs) != 0 {
		t.Fatalf("%+v %v", res, err)
	}
	if got := ghCommands(t); !slices.Equal(got, []string{"graphql", "graphql"}) {
		t.Fatalf("%q", got)
	}
}

// Update asks GitHub to update the PR, then fetches the branch, so the local
// repo has the new PR head.
func TestUpdateUpdatesThePRAndFetchesItsHead(t *testing.T) {
	e := setup(t)
	e.landing(func(head string) string {
		return strings.Replace(landState(head), `"mergeStateStatus": "CLEAN"`, `"mergeStateStatus": "BEHIND"`, 1)
	})
	// GitHub adds a merge commit to the branch. Here another clone pushes one.
	other := filepath.Join(t.TempDir(), "other")
	testutil.Git(t, filepath.Dir(other), "clone", "--branch", "fix-login", e.remote, other)
	commit(t, other, "update.txt", "u\n")
	testutil.Git(t, other, "push", "origin", "fix-login")
	newHead := testutil.Git(t, other, "rev-parse", "HEAD")

	res, err := worktree.Update(context.Background(), e.s, e.plot.ID, "", "fix-login")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Fetched || res.FetchNote != "" || res.PR.Number != 15 {
		t.Fatalf("%+v", res)
	}
	if got := ghCommands(t); !slices.Equal(got, []string{"graphql", "graphql", "pr update-branch 15 --repo github.com/example/widgets"}) {
		t.Fatalf("%q", got)
	}
	if got := testutil.Git(t, e.repo, "rev-parse", "refs/remotes/origin/fix-login"); got != newHead {
		t.Fatalf("origin/fix-login is %s, want %s", got, newHead)
	}
}

// A fetch that fails after the update is a note: GitHub has the update.
func TestUpdateNotesAFailedFetch(t *testing.T) {
	e := setup(t)
	e.landing(landState)
	t.Setenv("GIT_SSH_COMMAND", "false")
	res, err := worktree.Update(context.Background(), e.s, e.plot.ID, "", "fix-login")
	if err != nil || res.Fetched || res.FetchNote == "" {
		t.Fatalf("%+v %v", res, err)
	}
}

func TestRerunAndUpdateNeedAnOpenPR(t *testing.T) {
	e := setup(t)
	e.landing(func(head string) string {
		return strings.Replace(landState(head), `"state": "OPEN"`, `"state": "MERGED"`, 1)
	})
	if _, err := worktree.Rerun(context.Background(), e.s, e.plot.ID, "", "fix-login"); err == nil {
		t.Fatal("rerun: want an error")
	}
	if _, err := worktree.Update(context.Background(), e.s, e.plot.ID, "", "fix-login"); err == nil {
		t.Fatal("update: want an error")
	}
	if got := ghCommands(t); slices.ContainsFunc(got, func(c string) bool { return c != "graphql" }) {
		t.Fatalf("%q", got)
	}
}
