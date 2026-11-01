package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-217: the session of a run can write the git folder of the repo, and
// git worktree prune there deletes the metadata of each worktree that its
// sandbox does not show. A tick rebuilds the metadata of a run worktree.

// pruneMetadata deletes the metadata of the worktree in dir, as git worktree
// prune does in a sandbox that does not show dir, and returns its folder.
func pruneMetadata(t *testing.T, dir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	admin := strings.TrimPrefix(strings.TrimSpace(string(b)), "gitdir: ")
	if err := os.RemoveAll(admin); err != nil {
		t.Fatal(err)
	}
	return admin
}

func TestRunTickRebuildsTheGitMetadataOfAPrunedWorktree(t *testing.T) {
	s, r, w := shipRun(t, "3")
	head := testutil.Git(t, r.Folder, "rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(r.Folder, "hello.txt"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(r.Folder, "draft.txt"), []byte("draft\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	pruneMetadata(t, r.Folder)

	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunShipping || got.Runs[0].PR == nil {
		t.Fatalf("%+v", got)
	}
	if h := testutil.Git(t, r.Folder, "rev-parse", "HEAD"); h != head {
		t.Fatalf("HEAD %s, want %s", h, head)
	}
	if st := testutil.Git(t, r.Folder, "status", "--porcelain"); st != "M hello.txt\n?? draft.txt" {
		t.Fatalf("status %q", st)
	}
	if b, _ := os.ReadFile(filepath.Join(r.Folder, "hello.txt")); string(b) != "changed\n" {
		t.Fatalf("hello.txt is %q", b)
	}
	e := events(t, s, r.ID, "git")
	if len(e) != 1 || !strings.Contains(e[0], w.Path) || !strings.Contains(e[0], w.Branch) {
		t.Fatalf("git events %q", e)
	}
	// Git knows the worktree again, so the next tick rebuilds nothing.
	tick(t)
	if e := events(t, s, r.ID, "git"); len(e) != 1 {
		t.Fatalf("git events %q", e)
	}
}

func TestRunTickStopsARunWhoseBranchIsGoneWithItsMetadata(t *testing.T) {
	s, r, w := shipRun(t, "3")
	admin := pruneMetadata(t, r.Folder)
	testutil.Git(t, w.Repo, "update-ref", "-d", "refs/heads/"+w.Branch)

	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunStopped ||
		!strings.Contains(got.Runs[0].Note, w.Path) || !strings.Contains(got.Runs[0].Note, "the branch "+w.Branch+" is gone") {
		t.Fatalf("%+v", got)
	}
	if _, err := os.Lstat(admin); !os.IsNotExist(err) {
		t.Fatalf("Loam wrote %s: %v", admin, err)
	}
	if e := events(t, s, r.ID, "git"); len(e) != 0 {
		t.Fatalf("git events %q", e)
	}
}
