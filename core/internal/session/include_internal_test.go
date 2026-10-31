package session

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// includeEntries expands ~/ and relative paths as git does, and leaves out
// a path that git expands in another way and a folder.
func TestIncludeEntries(t *testing.T) {
	dir := realTempDir(t)
	if err := os.Mkdir(filepath.Join(dir, "folder"), 0o755); err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(dir, "gitconfig")
	text := "[include]\n\tpath = ~/a.gitconfig\n\tpath = rel/b.gitconfig\n\tpath = ~user/c\n\tpath = %(prefix)/d\n\tpath = folder\n" +
		"[includeIf \"hasconfig:remote.*.url:git@example.com:Org/**\"]\n\tpath = /abs/e.gitconfig\n"
	if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(dir, "home")
	if err := os.Mkdir(home, 0o755); err != nil {
		t.Fatal(err)
	}
	got, unread, err := includeEntries(context.Background(), home, f)
	want := []string{filepath.Join(home, "a.gitconfig"), filepath.Join(dir, "rel", "b.gitconfig"), "/abs/e.gitconfig"}
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
	dir := realTempDir(t)
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

// On a volume that ignores case, a cycle through two names of one file ends,
// and gitIncludes gives the other name once.
func TestGitIncludesEndsOnACycleThroughTwoNames(t *testing.T) {
	dir := realTempDir(t)
	if _, err := os.Stat(strings.ToUpper(dir)); err != nil {
		t.Skip("the folder is case-sensitive, so the two names are two files")
	}
	a := filepath.Join(dir, "a.gitconfig")
	if err := os.WriteFile(a, []byte("[include]\n\tpath = A.gitconfig\n\tpath = a.gitconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := gitIncludes("/home", []string{a}, func(string) bool { return true })
	if want := []string{filepath.Join(dir, "A.gitconfig")}; !slices.Equal(got.files, want) || got.late {
		t.Errorf("gitIncludes = %+v, want only %s", got, want)
	}
}

// Git resolves a relative include from the folder of the name that it opened.
// Two links in two folders name one file, which includes child.gitconfig, so
// gitIncludes gives the child of each folder.
func TestGitIncludesFollowsOneFileThroughLinksInTwoFolders(t *testing.T) {
	dir := realTempDir(t)
	shared := filepath.Join(dir, "shared.gitconfig")
	if err := os.WriteFile(shared, []byte("[include]\n\tpath = child.gitconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, d := range []string{"one", "two"} {
		if err := os.Mkdir(filepath.Join(dir, d), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(shared, filepath.Join(dir, d, "x.gitconfig")); err != nil {
			t.Fatal(err)
		}
		want = append(want, filepath.Join(dir, d, "child.gitconfig"))
	}
	a := filepath.Join(dir, "a.gitconfig")
	if err := os.WriteFile(a, []byte("[include]\n\tpath = one/x.gitconfig\n\tpath = two/x.gitconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := gitIncludes("/home", []string{a}, func(string) bool { return true })
	for _, w := range want {
		if !slices.Contains(got.files, w) {
			t.Errorf("gitIncludes = %+v, want %s", got, w)
		}
	}
}

// A link to its own folder gives a new name on each pass of a cycle, but the
// same real file and folder, so the cycle ends at once.
func TestGitIncludesEndsOnACycleThroughALinkToItsFolder(t *testing.T) {
	dir := realTempDir(t)
	if err := os.Symlink(".", filepath.Join(dir, "self")); err != nil {
		t.Fatal(err)
	}
	a := filepath.Join(dir, "a.gitconfig")
	if err := os.WriteFile(a, []byte("[include]\n\tpath = self/a.gitconfig\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := gitIncludes("/home", []string{a}, func(string) bool { return true })
	if got.files != nil || got.late {
		t.Errorf("gitIncludes = %+v, want no file", got)
	}
}

// gitIncludes takes the file of an entry in a file that it does not follow,
// such as one that the run can write, but not the files that that file
// includes. It names such a file in skipped.
func TestGitIncludesSkipsAFileThatItDoesNotFollow(t *testing.T) {
	dir := realTempDir(t)
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

// Git does not clean an include path, so the system follows each link before
// a "..": in the folder of the config file, in a relative value, in a ~/
// value, and in an absolute value. A path whose folder does not exist is
// cleaned by the text.
func TestIncludeEntriesFollowsALinkBeforeDotDot(t *testing.T) {
	dir := realTempDir(t)
	target := filepath.Join(dir, "elsewhere", "d")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "home", "link")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "other", "q")
	if err := os.MkdirAll(other, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, filepath.Join(target, "sub")); err != nil {
		t.Fatal(err)
	}
	f := filepath.Join(target, "x.gitconfig")
	text := "[include]\n\tpath = ../a.gitconfig\n\tpath = sub/../b.gitconfig\n" +
		"\tpath = ~/link/../c.gitconfig\n\tpath = " + link + "/../d.gitconfig\n\tpath = /nowhere/x/../e.gitconfig\n"
	if err := os.WriteFile(f, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	// f is read through the link, so its folder is the link.
	got, _, err := includeEntries(context.Background(), filepath.Join(dir, "home"), filepath.Join(link, "x.gitconfig"))
	elsewhere := filepath.Join(dir, "elsewhere")
	want := []string{
		filepath.Join(elsewhere, "a.gitconfig"), filepath.Join(dir, "other", "b.gitconfig"),
		filepath.Join(elsewhere, "c.gitconfig"), filepath.Join(elsewhere, "d.gitconfig"), "/nowhere/e.gitconfig",
	}
	if err != nil || !slices.Equal(got, want) {
		t.Errorf("includeEntries = %q, %v, want %q", got, err, want)
	}
}

// realTempDir is a temporary folder with its links resolved: on macOS, the
// temporary folder is behind the link /var.
func realTempDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}
