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
