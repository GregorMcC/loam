package session

import (
	"os"
	"path/filepath"
	"testing"
)

// A link to the root, the home folder, or a parent of the home folder adds no
// folder. add_link needs no approval, so such a link would otherwise give the
// next session every file of the account.
func TestLocalDirSkipsBroadFolders(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "Users", "me")
	docs := filepath.Join(home, "Documents")
	if err := os.MkdirAll(docs, 0o755); err != nil {
		t.Fatal(err)
	}
	note := filepath.Join(docs, "note.md")
	topFile := filepath.Join(home, "top.md")
	for _, p := range []string{note, topFile} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HOME", home)

	for target, want := range map[string]string{
		"/":                            "",
		root:                           "",
		filepath.Join(root, "Users"):   "",
		home:                           "",
		"~":                            "",
		topFile:                        "", // its folder is the home folder
		docs:                           docs,
		note:                           docs,
		"https://example.com":          "",
		filepath.Join(home, "missing"): "",
	} {
		if got := localDir(target); got != want {
			t.Errorf("localDir(%q) = %q, want %q", target, got, want)
		}
	}
}
