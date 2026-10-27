package claudebin_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func writeExe(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestFindUsesPathFirst(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeExe(t, filepath.Join(home, ".local/bin/claude"))
	dir := t.TempDir()
	writeExe(t, filepath.Join(dir, "claude"))
	t.Setenv("PATH", dir)
	got, err := claudebin.Find()
	if err != nil || got != filepath.Join(dir, "claude") {
		t.Fatalf("got %q, %v", got, err)
	}
}

// A GUI app's login shell reads .zprofile but not .zshrc, and Claude Code's
// installer adds ~/.local/bin to PATH in .zshrc.
func TestFindFallsBackToTheInstallFolders(t *testing.T) {
	for _, rel := range []string{".local/bin/claude", ".claude/local/claude"} {
		t.Run(rel, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			t.Setenv("PATH", t.TempDir())
			writeExe(t, filepath.Join(home, rel))
			got, err := claudebin.Find()
			if err != nil || got != filepath.Join(home, rel) {
				t.Fatalf("got %q, %v", got, err)
			}
		})
	}
}

func TestFindSkipsAFileThatCannotRun(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", t.TempDir())
	p := filepath.Join(home, ".local/bin/claude")
	writeExe(t, p)
	if err := os.Chmod(p, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".claude/local/claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := claudebin.Find(); err != claudebin.ErrNotFound {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestFindFailsWithNoClaude(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", t.TempDir())
	if got, err := claudebin.Find(); err != claudebin.ErrNotFound {
		t.Fatalf("got %q, %v", got, err)
	}
}

// writeTrust points CLAUDE_CONFIG_DIR at a config that trusts dirs.
func writeTrust(t *testing.T, dirs ...string) {
	t.Helper()
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	projects := map[string]any{}
	for _, d := range dirs {
		projects[d] = map[string]bool{"hasTrustDialogAccepted": true}
	}
	b, _ := json.Marshal(map[string]any{"projects": projects})
	if err := os.WriteFile(filepath.Join(cfg, ".claude.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestTrustedOutsideGitCountsParents(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	trusted := filepath.Join(root, "plots")
	child := filepath.Join(trusted, "abc", "notes")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	if claudebin.Trusted(child) {
		t.Fatal("trusted with no config file")
	}
	writeTrust(t, trusted)
	for dir, want := range map[string]bool{trusted: true, child: true, root: false} {
		if got := claudebin.Trusted(dir); got != want {
			t.Errorf("%s: trusted %v, want %v", dir, got, want)
		}
	}
}

// Claude Code trusts a git worktree when it trusts the main checkout of the
// repo. A trusted parent of the main checkout does not count.
func TestTrustedInGitFollowsTheMainCheckout(t *testing.T) {
	testutil.GitEnv(t)
	root, _ := filepath.EvalSymlinks(t.TempDir())
	repo := filepath.Join(root, "work", "app")
	wt := filepath.Join(root, "worktrees", "app-fix")
	if err := os.MkdirAll(filepath.Join(repo, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, repo, "init", "-q", "-b", "main")
	testutil.Git(t, repo, "commit", "-q", "--allow-empty", "-m", "first")
	testutil.Git(t, repo, "worktree", "add", "-q", "-b", "fix", wt)

	writeTrust(t, root)
	if claudebin.Trusted(wt) || claudebin.Trusted(repo) {
		t.Fatal("a trusted parent of the repo trusted it")
	}
	writeTrust(t, repo)
	for _, dir := range []string{repo, filepath.Join(repo, "src"), wt} {
		if !claudebin.Trusted(dir) {
			t.Errorf("%s: not trusted", dir)
		}
	}
}
