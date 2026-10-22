package worktree_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

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
