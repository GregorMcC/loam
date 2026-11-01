package worktree_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// noLock is the lock of a rebuild in a test, which runs one at a time.
func noLock(context.Context) (func(), error) { return func() {}, nil }

// adminOf returns the metadata folder that the .git file of the worktree in
// dir names.
func adminOf(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimPrefix(strings.TrimSpace(string(b)), "gitdir: ")
}

func TestRebuildLeavesAWorktreeThatGitKnows(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	before := testutil.Git(t, w.Path, "rev-parse", "HEAD")
	rebuilt, err := worktree.Rebuild(context.Background(), w, noLock)
	if err != nil || rebuilt {
		t.Fatalf("rebuilt %v, %v", rebuilt, err)
	}
	if got := testutil.Git(t, w.Path, "rev-parse", "HEAD"); got != before {
		t.Fatalf("HEAD %s, want %s", got, before)
	}
}

func TestRebuildRebuildsPrunedMetadataAndKeepsTheFiles(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	commit(t, w.Path, "a.txt", "one\n")
	head := testutil.Git(t, w.Path, "rev-parse", "HEAD")
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(w.Path, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.txt", "two\n")
	write("new.txt", "new\n")
	admin := adminOf(t, w.Path)
	// As git worktree prune in a sandbox that does not show the folder.
	if err := os.RemoveAll(filepath.Dir(admin)); err != nil {
		t.Fatal(err)
	}
	rebuilt, err := worktree.Rebuild(context.Background(), w, noLock)
	if err != nil || !rebuilt {
		t.Fatalf("rebuilt %v, %v", rebuilt, err)
	}
	if got := testutil.Git(t, w.Path, "rev-parse", "HEAD"); got != head {
		t.Fatalf("HEAD %s, want %s", got, head)
	}
	if got := testutil.Git(t, w.Path, "symbolic-ref", "HEAD"); got != "refs/heads/"+w.Branch {
		t.Fatalf("HEAD names %s", got)
	}
	if got := testutil.Git(t, w.Path, "status", "--porcelain"); got != "M a.txt\n?? new.txt" {
		t.Fatalf("status %q", got)
	}
	if b, _ := os.ReadFile(filepath.Join(w.Path, "a.txt")); string(b) != "two\n" {
		t.Fatalf("a.txt is %q", b)
	}
	real, err := filepath.EvalSymlinks(w.Path)
	if err != nil {
		t.Fatal(err)
	}
	if list := testutil.Git(t, e.repo, "worktree", "list", "--porcelain"); !strings.Contains(list, "worktree "+real+"\n") {
		t.Fatalf("git does not list the worktree:\n%s", list)
	}
	// A prune in the repo, which shows the folder, keeps the metadata now.
	testutil.Git(t, e.repo, "worktree", "prune")
	if _, err := os.Stat(admin); err != nil {
		t.Fatal(err)
	}
}

func TestRebuildRefusesAGoneBranch(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	admin := adminOf(t, w.Path)
	if err := os.RemoveAll(admin); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, e.repo, "update-ref", "-d", "refs/heads/"+w.Branch)
	_, err := worktree.Rebuild(context.Background(), w, noLock)
	var re *worktree.RebuildError
	if !errors.As(err, &re) || !strings.Contains(err.Error(), w.Path) || !strings.Contains(err.Error(), "the branch "+w.Branch+" is gone") {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Lstat(admin); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Loam wrote %s: %v", admin, err)
	}
}

func TestRebuildRefusesAGitFileThatNamesAFolderOutsideTheRepo(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	other := filepath.Join(t.TempDir(), "other.git", "worktrees", "feature")
	if err := os.WriteFile(filepath.Join(w.Path, ".git"), []byte("gitdir: "+other+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := worktree.Rebuild(context.Background(), w, noLock)
	var re *worktree.RebuildError
	if !errors.As(err, &re) || !strings.Contains(err.Error(), w.Path) || !strings.Contains(err.Error(), "outside the git folder") {
		t.Fatalf("err %v", err)
	}
	if _, err := os.Lstat(other); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Loam wrote %s: %v", other, err)
	}
}

func TestRebuildLeavesAGoneFolder(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	if err := os.RemoveAll(w.Path); err != nil {
		t.Fatal(err)
	}
	if rebuilt, err := worktree.Rebuild(context.Background(), w, noLock); err != nil || rebuilt {
		t.Fatalf("rebuilt %v, %v", rebuilt, err)
	}
}

// A process that finds the metadata gone waits for the lock, and then finds
// the metadata that another process rebuilt meanwhile: it writes nothing.
func TestRebuildChecksAgainAfterTheLock(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	admin := adminOf(t, w.Path)
	if err := os.RemoveAll(admin); err != nil {
		t.Fatal(err)
	}
	locked := false
	other := func(context.Context) (func(), error) {
		locked = true
		if err := os.Mkdir(admin, 0o755); err != nil {
			t.Fatal(err)
		}
		return func() {}, nil
	}
	rebuilt, err := worktree.Rebuild(context.Background(), w, other)
	if err != nil || rebuilt || !locked {
		t.Fatalf("rebuilt %v, locked %v, %v", rebuilt, locked, err)
	}
	if entries, _ := os.ReadDir(admin); len(entries) != 0 {
		t.Fatalf("Loam wrote in the metadata of the other process: %v", entries)
	}
	// A worktree that git knows takes no lock.
	locked = false
	if _, err := worktree.Rebuild(context.Background(), w, other); err != nil || locked {
		t.Fatalf("locked %v, %v", locked, err)
	}
}

// Only a .git file that is gone means a gone worktree. Another error reaches
// the caller.
func TestRebuildReturnsAnErrorThatIsNotAGoneFile(t *testing.T) {
	e := setup(t)
	w := e.create("feature", "").Worktree
	if err := os.Chmod(w.Path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(w.Path, 0o755) })
	if _, err := worktree.Rebuild(context.Background(), w, noLock); err == nil {
		t.Fatal("no error for a .git file that Loam cannot read")
	}
}
