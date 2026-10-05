package worktree_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// defaultRepo makes a clone on the branch "feature", and moves main on the
// remote past the local main. It returns the clone, the remote, and the new
// commit of origin/main.
func defaultRepo(t *testing.T) (repo, remote, head string) {
	t.Helper()
	testutil.GitEnv(t)
	repo, remote = testutil.GitRepo(t)
	other := filepath.Join(t.TempDir(), "other")
	testutil.Git(t, filepath.Dir(other), "clone", remote, other)
	commit(t, other, "new.txt", "new\n")
	testutil.Git(t, other, "push", "origin", "main")
	head = testutil.Git(t, other, "rev-parse", "HEAD")
	testutil.Git(t, repo, "switch", "-c", "feature")
	commit(t, repo, "feature.txt", "f\n")
	return repo, remote, head
}

func branchOf(t *testing.T, repo string) string {
	t.Helper()
	return testutil.Git(t, repo, "branch", "--show-current")
}

// Ticket 91: a repo add puts the checkout on the remote's default branch, at
// the remote's latest commit.
func TestSwitchToDefaultSwitchesAndFastForwards(t *testing.T) {
	repo, _, head := defaultRepo(t)
	if w := worktree.SwitchToDefault(repo); len(w) != 0 {
		t.Fatalf("warnings %v", w)
	}
	if b := branchOf(t, repo); b != "main" {
		t.Fatalf("branch %q", b)
	}
	if got := testutil.Git(t, repo, "rev-parse", "HEAD"); got != head {
		t.Fatalf("HEAD %s, want %s", got, head)
	}
	// The feature branch keeps its work.
	if out := testutil.Git(t, repo, "log", "--oneline", "feature"); !strings.Contains(out, "add feature.txt") {
		t.Fatalf("feature log %s", out)
	}
}

func TestSwitchToDefaultMakesTheLocalBranch(t *testing.T) {
	repo, _, head := defaultRepo(t)
	testutil.Git(t, repo, "branch", "-D", "main")
	if w := worktree.SwitchToDefault(repo); len(w) != 0 {
		t.Fatalf("warnings %v", w)
	}
	if b := branchOf(t, repo); b != "main" {
		t.Fatalf("branch %q", b)
	}
	if got := testutil.Git(t, repo, "rev-parse", "HEAD"); got != head {
		t.Fatalf("HEAD %s, want %s", got, head)
	}
	if up := testutil.Git(t, repo, "rev-parse", "--abbrev-ref", "main@{upstream}"); up != "origin/main" {
		t.Fatalf("upstream %q", up)
	}
}

func TestSwitchToDefaultKeepsADirtyCheckout(t *testing.T) {
	repo, _, _ := defaultRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "feature.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := worktree.SwitchToDefault(repo)
	if len(w) != 1 || !strings.Contains(w[0], "uncommitted changes") || !strings.Contains(w[0], "feature") {
		t.Fatalf("warnings %v", w)
	}
	if b := branchOf(t, repo); b != "feature" {
		t.Fatalf("branch %q", b)
	}
}

func TestSwitchToDefaultKeepsADetachedHeadWithOwnCommits(t *testing.T) {
	repo, _, head := defaultRepo(t)
	testutil.Git(t, repo, "switch", "--detach")
	commit(t, repo, "loose.txt", "l\n")
	w := worktree.SwitchToDefault(repo)
	if len(w) != 1 || !strings.Contains(w[0], "detached HEAD") || branchOf(t, repo) != "" {
		t.Fatalf("warnings %v, branch %q", w, branchOf(t, repo))
	}

	// A detached HEAD that a branch holds is switched.
	testutil.Git(t, repo, "switch", "--detach", "feature")
	if w := worktree.SwitchToDefault(repo); len(w) != 0 || branchOf(t, repo) != "main" {
		t.Fatalf("warnings %v, branch %q", w, branchOf(t, repo))
	}
	if got := testutil.Git(t, repo, "rev-parse", "HEAD"); got != head {
		t.Fatalf("HEAD %s, want %s", got, head)
	}
}

func TestSwitchToDefaultIgnoresUntrackedFiles(t *testing.T) {
	repo, _, _ := defaultRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "scratch.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w := worktree.SwitchToDefault(repo); len(w) != 0 {
		t.Fatalf("warnings %v", w)
	}
	if b := branchOf(t, repo); b != "main" {
		t.Fatalf("branch %q", b)
	}
}

func TestSwitchToDefaultWarnsWhenMainHasDiverged(t *testing.T) {
	repo, _, head := defaultRepo(t)
	testutil.Git(t, repo, "switch", "main")
	commit(t, repo, "local.txt", "l\n")
	testutil.Git(t, repo, "switch", "feature")
	w := worktree.SwitchToDefault(repo)
	if len(w) != 1 || !strings.Contains(w[0], "origin/main") {
		t.Fatalf("warnings %v", w)
	}
	if b := branchOf(t, repo); b != "main" {
		t.Fatalf("branch %q", b)
	}
	if got := testutil.Git(t, repo, "rev-parse", "HEAD"); got == head {
		t.Fatal("a diverged main must keep its own commit")
	}
}

func TestSwitchToDefaultLeavesOtherCheckoutsAlone(t *testing.T) {
	// No remote.
	repo, _, _ := defaultRepo(t)
	testutil.Git(t, repo, "remote", "remove", "origin")
	if w := worktree.SwitchToDefault(repo); len(w) != 0 || branchOf(t, repo) != "feature" {
		t.Fatalf("no remote: warnings %v, branch %q", w, branchOf(t, repo))
	}

	// A linked worktree is on its branch on purpose.
	repo, _, _ = defaultRepo(t)
	linked := filepath.Join(t.TempDir(), "linked")
	testutil.Git(t, repo, "worktree", "add", "-b", "side", linked)
	if w := worktree.SwitchToDefault(linked); len(w) != 0 || branchOf(t, linked) != "side" {
		t.Fatalf("linked: warnings %v, branch %q", w, branchOf(t, linked))
	}

	// A repo with no commits, and a folder that is not a repo.
	empty := t.TempDir()
	testutil.Git(t, empty, "init", "-q")
	testutil.Git(t, empty, "remote", "add", "origin", "git@github.invalid:me/app.git")
	if w := worktree.SwitchToDefault(empty); len(w) != 0 {
		t.Fatalf("empty: warnings %v", w)
	}
	if w := worktree.SwitchToDefault(t.TempDir()); len(w) != 0 {
		t.Fatalf("plain folder: warnings %v", w)
	}
}
