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
	rebuilt, err := worktree.Rebuild(context.Background(), w)
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
	rebuilt, err := worktree.Rebuild(context.Background(), w)
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
	_, err := worktree.Rebuild(context.Background(), w)
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
	_, err := worktree.Rebuild(context.Background(), w)
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
	if rebuilt, err := worktree.Rebuild(context.Background(), w); err != nil || rebuilt {
		t.Fatalf("rebuilt %v, %v", rebuilt, err)
	}
}
