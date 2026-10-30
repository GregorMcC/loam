package session

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// includeEntries expands ~/ and relative paths as git does, and leaves out
// a path that git expands in another way and a folder.
func TestIncludeEntries(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "folder"), 0o755); err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(dir, "gitconfig")
	text := "[include]\n\tpath = ~/a.gitconfig\n\tpath = rel/b.gitconfig\n\tpath = ~user/c\n\tpath = %(prefix)/d\n\tpath = folder\n" +
		"[includeIf \"hasconfig:remote.*.url:git@example.com:Org/**\"]\n\tpath = /abs/e.gitconfig\n"
	if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	got, ok := includeEntries(context.Background(), "/home", f)
	want := []includeEntry{
		{"include.path", "/home/a.gitconfig"},
		{"include.path", filepath.Join(dir, "rel", "b.gitconfig")},
		{"includeif.hasconfig:remote.*.url:git@example.com:org/**.path", "/abs/e.gitconfig"},
	}
	if !ok || !slices.Equal(got, want) {
		t.Errorf("includeEntries = %q, %v, want %q", got, ok, want)
	}
}

// gitIncludes ends on a cycle, and gives the files once.
func TestGitIncludesEndsOnACycle(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a.gitconfig"), filepath.Join(dir, "b.gitconfig")
	for f, text := range map[string]string{a: "[include]\n\tpath = b.gitconfig\n", b: "[include]\n\tpath = a.gitconfig\n"} {
		if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := gitIncludes("/home", []string{a}, nil, func(string) bool { return false })
	if !slices.Equal(got.files, []string{b}) || got.late || got.skipped != nil {
		t.Errorf("gitIncludes = %+v, want only %s", got, b)
	}
}
