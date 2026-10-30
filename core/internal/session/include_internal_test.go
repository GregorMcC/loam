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
	got, unread, err := includeEntries(context.Background(), "/home", f)
	want := []string{"/home/a.gitconfig", filepath.Join(dir, "rel", "b.gitconfig"), "/abs/e.gitconfig"}
	if err != nil || !slices.Equal(got, want) || !slices.Equal(unread, []string{"~user/c", "%(prefix)/d"}) {
		t.Errorf("includeEntries = %q, %q, %v, want %q and the two paths that Loam does not expand", got, unread, err, want)
	}
	// Git skips a missing include file, so it gives none.
	if got, unread, err := includeEntries(context.Background(), "/home", filepath.Join(dir, "missing")); got != nil || unread != nil || err != nil {
		t.Errorf("includeEntries of a missing file = %q, %q, %v, want none", got, unread, err)
	}
	bad := filepath.Join(dir, "bad")
	if err := os.WriteFile(bad, []byte("[bad\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := includeEntries(context.Background(), "/home", bad); err == nil {
		t.Error("includeEntries of a file that git cannot read gives no error")
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
	got := gitIncludes("/home", []string{a}, func(string) bool { return true })
	if !slices.Equal(got.files, []string{b}) || got.late || got.skipped != nil {
		t.Errorf("gitIncludes = %+v, want only %s", got, b)
	}
}

// gitIncludes takes the file of an entry in a file that it does not follow,
// such as one that the run can write, but not the files that that file
// includes. It names such a file in skipped.
func TestGitIncludesSkipsAFileThatItDoesNotFollow(t *testing.T) {
	dir := t.TempDir()
	a, b, c := filepath.Join(dir, "a.gitconfig"), filepath.Join(dir, "b.gitconfig"), filepath.Join(dir, "c.gitconfig")
	for f, text := range map[string]string{
		a: "[include]\n\tpath = b.gitconfig\n",
		b: "[include]\n\tpath = c.gitconfig\n",
		c: "",
	} {
		if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := gitIncludes("/home", []string{a}, func(f string) bool { return f != b })
	if !slices.Equal(got.files, []string{b}) || !slices.Equal(got.skipped, []string{b}) || got.late {
		t.Errorf("gitIncludes = %+v, want %s, and skipped", got, b)
	}
}
