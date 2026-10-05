package editor_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/editor"
)

func script(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "ed.sh")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestEditReturnsEditedText(t *testing.T) {
	t.Setenv("VISUAL", script(t, `printf ' edited' >> "$1"`))
	t.Setenv("EDITOR", "false")
	got, err := editor.Edit("start")
	if err != nil || got != "start edited" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestEditorFallsBackToEDITORWithArguments(t *testing.T) {
	t.Setenv("VISUAL", "")
	t.Setenv("EDITOR", script(t, `for f; do :; done; printf 'from EDITOR' > "$f"`)+" --wait")
	got, err := editor.Edit("x")
	if err != nil || got != "from EDITOR" {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestEditFailureKeepsFile(t *testing.T) {
	t.Setenv("VISUAL", script(t, `exit 3`))
	_, err := editor.Edit("my text")
	if err == nil {
		t.Fatal("want an error")
	}
	path := editor.KeptFile(err)
	if path == "" {
		t.Fatal("want the kept file path in the error")
	}
	defer os.Remove(path)
	b, rerr := os.ReadFile(path)
	if rerr != nil || string(b) != "my text" {
		t.Fatalf("kept file: %q, %v", b, rerr)
	}
}
