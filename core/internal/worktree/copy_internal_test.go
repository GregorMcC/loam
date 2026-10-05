package worktree

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestCopyFilesRefusesSymbolicLinks(t *testing.T) {
	repo, dest, outside := t.TempDir(), t.TempDir(), t.TempDir()
	mustWrite := func(p, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	mustLink := func(target, link string) {
		t.Helper()
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}

	// Source side: a linked folder and a linked file that point out of the repo.
	mustWrite(filepath.Join(outside, "secret", "id_rsa"), "key")
	mustLink(filepath.Join(outside, "secret"), filepath.Join(repo, "cfg"))
	mustLink(filepath.Join(outside, "secret", "id_rsa"), filepath.Join(repo, ".env"))
	// Destination side: a real folder in the repo, a link in the worktree.
	mustWrite(filepath.Join(repo, "la", "evil.plist"), "x")
	mustLink(outside, filepath.Join(dest, "la"))
	// A plain file still copies.
	mustWrite(filepath.Join(repo, "ok", "a.txt"), "a")

	copied, warnings := copyFiles(repo, dest, []string{"cfg/*", ".env", "la/*", "ok/*"}, nil)
	if !slices.Equal(copied, []string{"ok/a.txt"}) {
		t.Fatalf("copied %v, want only ok/a.txt (warnings %v)", copied, warnings)
	}
	if _, err := os.Stat(filepath.Join(outside, "evil.plist")); err == nil {
		t.Fatal("a file was written through a link out of the worktree")
	}
	for _, f := range []string{"cfg/id_rsa", ".env"} {
		if _, err := os.Lstat(filepath.Join(dest, f)); err == nil {
			t.Fatalf("%s was copied through a link out of the repo", f)
		}
	}
	joined := strings.Join(warnings, "\n")
	for _, want := range []string{"cfg/id_rsa", ".env", "la/evil.plist"} {
		if !strings.Contains(joined, want) {
			t.Errorf("no warning for %s: %v", want, warnings)
		}
	}
}
