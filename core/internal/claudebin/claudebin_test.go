package claudebin_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/claudebin"
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

func TestTrustedReadsClaudeCodeConfigAndParents(t *testing.T) {
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	root := t.TempDir()
	trusted := filepath.Join(root, "worktrees")
	child := filepath.Join(trusted, "plot", "app-fix")
	other := filepath.Join(root, "other")
	for _, d := range []string{child, other} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if claudebin.Trusted(child) {
		t.Fatal("trusted with no config file")
	}
	body := `{"projects":{"` + trusted + `":{"hasTrustDialogAccepted":true},"` + other + `":{"hasTrustDialogAccepted":false}}}`
	if err := os.WriteFile(filepath.Join(cfg, ".claude.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	for dir, want := range map[string]bool{trusted: true, child: true, other: false, root: false} {
		if got := claudebin.Trusted(dir); got != want {
			t.Errorf("%s: trusted %v, want %v", dir, got, want)
		}
	}
}
