package worktree_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// onGitHub points origin at a made-up GitHub repo and starts a fake gh that
// answers from state. From then on, no command may fetch.
func (e *env) onGitHub(state string) {
	e.t.Helper()
	testutil.Git(e.t, e.repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(e.t, state)
}

func (e *env) worktrees() []store.Worktree {
	e.t.Helper()
	ws, err := e.s.ListWorktrees(e.plot.ID)
	if err != nil {
		e.t.Fatal(err)
	}
	return ws
}

func (e *env) listed() map[string]worktree.Status {
	e.t.Helper()
	list, err := worktree.List(e.s, e.plot.ID)
	if err != nil {
		e.t.Fatal(err)
	}
	byName := map[string]worktree.Status{}
	for _, st := range list {
		byName[st.Worktree.Name] = st
	}
	return byName
}

// A refresh reads the worktrees, then asks GitHub. When loam worktree rm
// removes a worktree in that time, the cache gets no row for it.
func TestRefreshSkipsAWorktreeThatIsRemovedDuringTheRefresh(t *testing.T) {
	e := setup(t)
	e.create("fix-login", "")
	e.create("add-search", "")
	e.onGitHub(`{"refs": ["fix-login", "add-search"], "pulls": [], "details": {}}`)
	ws := e.worktrees()
	if err := e.s.RemoveWorktree(ws[0].ID); err != nil {
		t.Fatal(err)
	}
	if err := worktree.RefreshPRs(context.Background(), e.s, ws); err != nil {
		t.Fatal(err)
	}
	got, err := e.s.PRStates()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := got[store.PRKey{Repo: ws[0].Repo, Branch: ws[0].Branch}]; ok || len(got) != 1 {
		t.Fatalf("%+v", got)
	}
}

// A cancelled refresh (Ctrl-C, or a cancelled MCP call) stops gh and writes
// nothing: GitHub did not fail.
func TestRefreshStopsWhenTheContextIsCancelled(t *testing.T) {
	e := setup(t)
	e.create("fix-login", "")
	e.onGitHub(`{"refs": ["fix-login"], "pulls": [], "details": {}}`)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := worktree.RefreshPRs(ctx, e.s, e.worktrees()); !errors.Is(err, context.Canceled) {
		t.Fatalf("%v", err)
	}
	if got, err := e.s.PRStates(); err != nil || len(got) != 0 {
		t.Fatalf("%+v %v", got, err)
	}
}

// The compare page compares with the base of the worktree when the base is
// a branch of origin. Else GitHub compares with its default branch, because
// a local base may not be on GitHub.
func TestRefreshComparesWithTheBaseOnOrigin(t *testing.T) {
	e := setup(t)
	testutil.Git(t, e.repo, "checkout", "-b", "develop")
	testutil.Git(t, e.repo, "push", "origin", "develop")
	testutil.Git(t, e.repo, "checkout", "main")
	testutil.Git(t, e.repo, "branch", "mine")
	e.create("from-origin", "origin/develop")
	e.create("from-local", "develop")
	e.create("mine", "")
	e.create("fix#12", "origin/develop")
	e.onGitHub(`{"refs": ["from-origin", "from-local", "mine", "fix#12"], "pulls": [], "details": {}}`)
	if err := worktree.RefreshPRs(context.Background(), e.s, e.worktrees()); err != nil {
		t.Fatal(err)
	}
	const compare = "https://github.com/example/widgets/compare/"
	got := e.listed()
	for name, want := range map[string]string{
		"from-origin": compare + "develop...from-origin",
		"from-local":  compare + "from-local",
		"mine":        compare + "mine",
		"fix#12":      compare + "develop...fix%2312",
	} {
		if st := got[name]; st.Stage != worktree.StagePushedNoPR || st.CompareURL != want {
			t.Errorf("%s: %s %q, want %q", name, st.Stage, st.CompareURL, want)
		}
	}
}

// Merged wins only when the worktree has no work after the PR head. New work
// shows as if there were no PR. A squash merge leaves commits that no remote
// holds, and GitHub can delete the branch: the worktree is still merged.
func TestListShowsMergedOnlyWithNoWorkAfterThePRHead(t *testing.T) {
	e := setup(t)
	wt := e.create("old-work", "").Worktree
	commit(t, wt.Path, "work.txt", "w\n")
	head := testutil.Git(t, wt.Path, "rev-parse", "HEAD")
	e.onGitHub(fmt.Sprintf(`{"refs": [], "pulls": [
	  {"number": 9, "title": "Old work", "url": "https://github.com/example/widgets/pull/9", "state": "MERGED",
	   "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "baseRefName": "main", "headRefName": "old-work",
	   "headRefOid": %q, "mergedAt": "2026-01-01T09:00:00Z", "closedAt": "2026-01-01T09:00:00Z", "commits": {"totalCount": 1}}
	], "details": {}}`, head))
	if err := worktree.RefreshPRs(context.Background(), e.s, e.worktrees()); err != nil {
		t.Fatal(err)
	}
	if st := e.listed()["old-work"]; st.Stage != worktree.StageMerged || st.PR == nil || st.PR.Number != 9 || st.Unpushed != 1 {
		t.Fatalf("%+v", st)
	}

	// A changed file is work after the PR head.
	if err := os.WriteFile(filepath.Join(wt.Path, "notes.txt"), []byte("n\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if st := e.listed()["old-work"]; st.Stage != worktree.StageNotPushed || st.PR != nil || st.PRCheckedAt == nil {
		t.Fatalf("changed file: %+v", st)
	}

	// So is a new commit.
	testutil.Git(t, wt.Path, "add", ".")
	testutil.Git(t, wt.Path, "commit", "-m", "more")
	if st := e.listed()["old-work"]; st.Stage != worktree.StageNotPushed || st.PR != nil {
		t.Fatalf("new commit: %+v", st)
	}
}

// GitHub can add commits to a PR, such as with Update branch. A worktree
// whose HEAD is an earlier commit of the PR has no work after it, so it
// shows Merged. When the local repo does not have the PR head, Loam cannot
// read the history of the PR, and the worktree gets its local stage. A new
// worktree on the branch name of an old PR must not show that PR.
func TestListShowsMergedWhenGitHubAddedCommitsToThePR(t *testing.T) {
	e := setup(t)
	updated := e.create("updated", "").Worktree
	commit(t, updated.Path, "a.txt", "a\n")
	commit(t, updated.Path, "b.txt", "b\n")
	prHead := testutil.Git(t, updated.Path, "rev-parse", "HEAD")
	testutil.Git(t, updated.Path, "reset", "--hard", "HEAD~1")
	e.create("unfetched", "")
	newWork := e.create("unfetched-new-work", "").Worktree
	commit(t, newWork.Path, "c.txt", "c\n")

	const unfetched = "2222222222222222222222222222222222222222"
	pull := func(n int, branch, oid string) string {
		return fmt.Sprintf(`{"number": %d, "title": "Work", "url": "https://github.com/example/widgets/pull/%d", "state": "MERGED",
		  "mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN", "baseRefName": "main", "headRefName": %q,
		  "headRefOid": %q, "mergedAt": "2026-01-01T09:00:00Z", "closedAt": "2026-01-01T09:00:00Z", "commits": {"totalCount": 2}}`, n, n, branch, oid)
	}
	e.onGitHub(fmt.Sprintf(`{"refs": [], "pulls": [%s, %s, %s], "details": {}}`,
		pull(21, "updated", prHead), pull(22, "unfetched", unfetched), pull(23, "unfetched-new-work", unfetched)))
	if err := worktree.RefreshPRs(context.Background(), e.s, e.worktrees()); err != nil {
		t.Fatal(err)
	}
	got := e.listed()
	for name, want := range map[string]worktree.Stage{
		"updated":            worktree.StageMerged,
		"unfetched":          worktree.StageNone,
		"unfetched-new-work": worktree.StageNotPushed,
	} {
		if st := got[name]; st.Stage != want {
			t.Errorf("%s: got %q, want %q (%+v)", name, st.Stage, want, st)
		}
	}
}

// With gh missing or signed out, Loam cannot ask GitHub until you fix gh, so
// the list shows the local state of each worktree. The cache keeps the last
// state for the next refresh that gets an answer. Other failures keep
// showing the last state.
func TestListShowsLocalStateWhenGHIsMissingOrSignedOut(t *testing.T) {
	e := setup(t)
	wt := e.create("fix-login", "").Worktree
	commit(t, wt.Path, "fix.txt", "f\n")
	e.onGitHub(`{"refs": ["fix-login"], "pulls": [
	  {"number": 14, "title": "Fix login", "url": "https://github.com/example/widgets/pull/14", "state": "OPEN",
	   "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "baseRefName": "main", "headRefName": "fix-login",
	   "headRefOid": "1111111111111111111111111111111111111111", "commits": {"totalCount": 1}}
	], "details": {"14": {"checks": []}}}`)
	refresh := func() {
		t.Helper()
		if err := worktree.RefreshPRs(context.Background(), e.s, e.worktrees()); err != nil {
			t.Fatal(err)
		}
	}
	refresh()
	if st := e.listed()["fix-login"]; st.Stage != worktree.StageReadyToMerge || st.PR == nil {
		t.Fatalf("before: %+v", st)
	}

	gh := os.Getenv("LOAM_GH")
	for _, c := range []struct {
		name string
		fail func()
		note worktree.PRNote
		want worktree.Stage
	}{
		{"offline keeps the last state", func() { t.Setenv("LOAM_FAKE_GH_FAIL", "offline") }, worktree.NoteOffline, worktree.StageReadyToMerge},
		{"signed out", func() { t.Setenv("LOAM_FAKE_GH_FAIL", "signed_out") }, worktree.NoteGHSignedOut, worktree.StageNotPushed},
		{"missing", func() { t.Setenv("LOAM_GH", filepath.Join(t.TempDir(), "no-gh")) }, worktree.NoteGHMissing, worktree.StageNotPushed},
	} {
		c.fail()
		refresh()
		st := e.listed()["fix-login"]
		if st.PRNote != c.note || st.Stage != c.want {
			t.Errorf("%s: got note %q, stage %q", c.name, st.PRNote, st.Stage)
		}
		if local := c.want == worktree.StageNotPushed; local && (st.PR != nil || st.PRCheckedAt != nil || st.CompareURL != "") {
			t.Errorf("%s: shows ship state: %+v", c.name, st)
		}
	}

	// gh works again while GitHub checks the PR. Only the last stage in the
	// cache can give Ready to merge now, so the cache kept it.
	t.Setenv("LOAM_GH", gh)
	t.Setenv("LOAM_FAKE_GH_FAIL", "")
	file := os.Getenv("LOAM_FAKE_GH_STATE")
	b, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	checking := strings.Replace(string(b), `"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"`, `"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"`, 1)
	if err := os.WriteFile(file, []byte(checking), 0o644); err != nil {
		t.Fatal(err)
	}
	refresh()
	if st := e.listed()["fix-login"]; st.PRNote != "" || st.Stage != worktree.StageReadyToMerge || st.PR == nil || st.PRCheckedAt == nil {
		t.Fatalf("after gh works again: %+v", st)
	}
}

// The cache keeps the passed checks of an open PR, in the order of GitHub, with the fields of a failed check.
func TestListShowsThePassedChecksOfAnOpenPR(t *testing.T) {
	e := setup(t)
	e.create("fix-login", "")
	e.onGitHub(`{"refs": ["fix-login"], "pulls": [
	  {"number": 14, "title": "Fix login", "url": "https://github.com/example/widgets/pull/14", "state": "OPEN",
	   "mergeable": "MERGEABLE", "mergeStateStatus": "UNSTABLE", "baseRefName": "main", "headRefName": "fix-login",
	   "headRefOid": "1111111111111111111111111111111111111111", "commits": {"totalCount": 1}}
	], "details": {"14": {"commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE", "contexts": {"totalCount": 3, "nodes": [
	  {"__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS",
	   "detailsUrl": "https://github.com/example/widgets/actions/runs/7/job/1", "isRequired": true,
	   "startedAt": "2026-01-01T10:00:00Z", "completedAt": "2026-01-01T10:01:30Z"},
	  {"__typename": "CheckRun", "name": "docs", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": false},
	  {"__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS", "targetUrl": "https://ci.example.com/1", "isRequired": false}
	]}}}}]}}}}`)
	if err := worktree.RefreshPRs(context.Background(), e.s, e.worktrees()); err != nil {
		t.Fatal(err)
	}
	pr := e.listed()["fix-login"].PR
	if pr == nil {
		t.Fatal("no PR")
	}
	want := []github.Check{
		{Name: "build", URL: "https://github.com/example/widgets/actions/runs/7/job/1", Duration: 90, Required: true},
		{Name: "ci/legacy", URL: "https://ci.example.com/1"},
	}
	if !slices.Equal(pr.PassedChecks, want) || len(pr.PassedChecks) != pr.Checks.Passed {
		t.Fatalf("passed checks %+v", pr.PassedChecks)
	}
	if len(pr.FailedChecks) != 1 || pr.FailedChecks[0].Name != "docs" {
		t.Fatalf("failed checks %+v", pr.FailedChecks)
	}
}

// A row of the cache from before Loam stored the passed checks has no passed_checks, and one from before the
// reviews (TAS-60) has no change_requests or review_threads. Each lists as an empty list, never null, so the app
// reads one shape. The next refresh fills them.
func TestListGivesACachedPRFromBeforePassedChecksAnEmptyList(t *testing.T) {
	e := setup(t)
	e.create("fix-login", "")
	w := e.worktrees()[0]
	const before = `{"pr": {"number": 14, "title": "Fix login", "url": "https://github.com/example/widgets/pull/14", "state": "OPEN",
	  "draft": false, "mergeable": "MERGEABLE", "merge_state": "CLEAN", "review_decision": "", "in_merge_queue": false, "queue_position": 0,
	  "base": "main", "head": "fix-login", "head_oid": "1111111111111111111111111111111111111111", "commits": 1, "behind_base": 0,
	  "approvals": 0, "comments": 0, "checks": {"state": "SUCCESS", "total": 2, "passed": 2, "failed": 0, "running": 0, "waiting": 0,
	  "required": 0, "required_passed": 0}, "failed_checks": []}, "pushed": true, "stage": "ready_to_merge"}`
	row := store.PRState{PRKey: store.PRKey{Repo: w.Repo, Branch: w.Branch}, Data: before, CheckedAt: time.Now()}
	if err := e.s.SavePRStates([]store.PRState{row}); err != nil {
		t.Fatal(err)
	}
	st := e.listed()["fix-login"]
	if st.Stage != worktree.StageReadyToMerge || st.PR == nil || st.PR.Checks.Passed != 2 {
		t.Fatalf("%+v", st)
	}
	if st.PR.PassedChecks == nil || len(st.PR.PassedChecks) != 0 {
		t.Fatalf("passed checks %#v", st.PR.PassedChecks)
	}
	b, err := json.Marshal(st.PR)
	if err != nil {
		t.Fatal(err)
	}
	for _, list := range []string{`"passed_checks":[]`, `"change_requests":[]`, `"review_threads":[]`} {
		if !strings.Contains(string(b), list) {
			t.Fatalf("no %s: %s", list, b)
		}
	}
}
