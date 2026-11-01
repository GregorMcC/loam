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
	loamHome := filepath.Join(root, "loam")

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
		if got := localDir(target, loamHome); got != want {
			t.Errorf("localDir(%q) = %q, want %q", target, got, want)
		}
	}
}

// A link to a private folder of the account or to the Loam home adds no folder
// for any actor. A folder inside one of them is refused too, by its real path
// and in any case, as macOS folders do not tell case apart.
func TestLocalDirSkipsPrivateFolders(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	loamHome := filepath.Join(root, "apps", "loam")
	docs := filepath.Join(home, "Documents")
	hidden := filepath.Join(docs, ".hidden")
	inDocs := filepath.Join(docs, "Library")
	ssh := filepath.Join(home, ".ssh")
	gh := filepath.Join(home, ".config", "gh")
	keychains := filepath.Join(home, "Library", "Keychains")
	plots := filepath.Join(loamHome, "plots")
	for _, d := range []string{hidden, inDocs, ssh, gh, keychains, plots} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	key := filepath.Join(ssh, "id_ed25519")
	if err := os.WriteFile(key, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	linked := filepath.Join(docs, "keys")
	if err := os.Symlink(ssh, linked); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)

	for target, want := range map[string]string{
		ssh:                            "",
		"~/.ssh":                       "",
		filepath.Join(home, ".SSH"):    "",
		docs + "/../.ssh":              "",
		key:                            "", // its folder is ~/.ssh
		gh:                             "",
		filepath.Join(home, ".config"): "",
		filepath.Join(home, "Library"): "",
		filepath.Join(home, "library"): "",
		keychains:                      "",
		linked:                         "", // a symlink to ~/.ssh
		loamHome:                       "",
		plots:                          "",
		filepath.Dir(loamHome):         "", // it holds the Loam home
		docs:                           docs,
		hidden:                         hidden, // a dot folder, but not directly below home
		inDocs:                         inDocs,
	} {
		if got := localDir(target, loamHome); got != want {
			t.Errorf("localDir(%q) = %q, want %q", target, got, want)
		}
	}
}
