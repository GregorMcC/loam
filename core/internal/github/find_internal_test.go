package github

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func writeExe(t *testing.T, path string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// An app that the Finder starts has a short PATH with no Homebrew folder.
func TestFindSearchesPathThenTheInstallFolders(t *testing.T) {
	t.Setenv(ghEnv, "")
	installed := filepath.Join(t.TempDir(), "gh")
	writeExe(t, installed)
	saved := installPaths
	t.Cleanup(func() { installPaths = saved })
	installPaths = []string{filepath.Join(t.TempDir(), "gh"), installed}

	onPath := t.TempDir()
	writeExe(t, filepath.Join(onPath, "gh"))
	t.Setenv("PATH", onPath)
	if got, err := Find(); err != nil || got != filepath.Join(onPath, "gh") {
		t.Fatalf("got %q, %v", got, err)
	}

	t.Setenv("PATH", t.TempDir())
	if got, err := Find(); err != nil || got != installed {
		t.Fatalf("got %q, %v", got, err)
	}

	if err := os.Chmod(installed, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Find(); !errors.Is(err, ErrGHMissing) {
		t.Fatalf("%v", err)
	}
}
