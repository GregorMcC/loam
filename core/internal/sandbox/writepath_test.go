package sandbox

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// holdsWrite reports whether a write path of r holds path.
func holdsWrite(t *testing.T, r Rules, path string) bool {
	t.Helper()
	w, err := r.WritePathOf(path)
	if err != nil {
		t.Fatal(err)
	}
	return w != ""
}

// The compare takes whole path elements, ignores case and Unicode forms, and
// takes no deny rule into account.
func TestWritePathOfComparesAsTheVolumeDoes(t *testing.T) {
	r := Rules{Write: []string{"/w/Caf\u00e9"}, DenyWrite: []string{"/w/Caf\u00e9/.git/config"}}
	for path, want := range map[string]bool{
		"/w/Caf\u00e9":             true,
		"/w/Caf\u00e9/a":           true,
		"/w/caf\u00e9/a":           true,
		"/W/CAF\u00c9/A":           true,
		"/w/Cafe\u0301/a":          true,
		"/w/CAFE\u0301/a":          true,
		"/w/Caf\u00e9/.git/config": true,
		"/w/Caf\u00e9s/a":          false,
		"/w":                       false,
		"/elsewhere/a":             false,
	} {
		got, err := r.WritePathOf(path)
		if err != nil {
			t.Fatal(err)
		}
		if (got != "") != want {
			t.Errorf("WritePathOf(%q) = %q, want a write path: %v", path, got, want)
		}
	}
	if !holdsWrite(t, Rules{Write: []string{"/w/stra\u00dfe"}}, "/w/STRASSE/a") {
		t.Error("the compare does not fold the case of a character to two")
	}
}

func TestWritePathOfTakesAFolderOfAlsoAsAWritePath(t *testing.T) {
	got, err := Rules{}.WritePathOf("/t/a", "/t")
	if err != nil || got != "/t" {
		t.Errorf("WritePathOf = %q, %v, want /t", got, err)
	}
}

// Each way that a path can reach a write path, also when part of it is missing
// or when it ends outside.
func TestWritePathOfWalksThePathAsTheSystemDoes(t *testing.T) {
	root := realTemp(t)
	write, out := filepath.Join(root, "write"), filepath.Join(root, "out")
	for _, d := range []string{write, out, filepath.Join(out, "deep", "er"), filepath.Join(write, "sub")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	link := func(target, name string) string {
		t.Helper()
		p := filepath.Join(root, name)
		if err := os.Symlink(target, p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	toWrite := link(write, "out/to-write")
	dangling := link(filepath.Join(write, "missing"), "out/dangling")
	relative := link("../write/x", "out/relative")
	chain := link(dangling, "out/chain")
	up := link(filepath.Join(out, "deep", "er"), "out/up")
	writeUp := link(filepath.Join(write, "sub"), "out/write-up")
	inWrite := link(out, "write/to-out")
	r := Rules{Write: []string{write}}
	for name, c := range map[string]struct {
		path string
		want bool
	}{
		"a file":                                  {filepath.Join(write, "a"), true},
		"a missing folder below":                  {filepath.Join(write, "no", "such", "a"), true},
		"through a link":                          {filepath.Join(toWrite, "a"), true},
		"through a link to a missing folder":      {filepath.Join(toWrite, "no", "such", "a"), true},
		"a link to a missing file":                {dangling, true},
		"a relative link to a missing file":       {relative, true},
		"a chain of links":                        {chain, true},
		"a dot dot after the target of a link":    {up + "/../../../write/a", true},
		"a dot dot back from a missing name":      {out + "/none/../to-write/a", true},
		"a link in a write path to another path":  {filepath.Join(inWrite, "a"), true},
		"a path through a write path that leaves": {write + "/sub/../../out/a", true},
		"a dot dot from a link in the write path": {writeUp + "/../a", true},
		"beside":                           {filepath.Join(out, "a"), false},
		"a dot dot that a link moves away": {up + "/../a", false},
		"a dot dot out by the text":        {out + "/none/../a", false},
	} {
		got, err := r.WritePathOf(c.path)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if (got != "") != c.want {
			t.Errorf("%s: WritePathOf(%s) = %q, want a write path: %v", name, c.path, got, c.want)
		}
	}
}

// A write path behind a link counts by its real path too.
func TestWritePathOfResolvesAWritePathBehindALink(t *testing.T) {
	root := realTemp(t)
	real := filepath.Join(root, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(real, alias); err != nil {
		t.Fatal(err)
	}
	if !holdsWrite(t, Rules{Write: []string{alias}}, filepath.Join(real, "a")) {
		t.Error("the write path behind a link does not hold the path")
	}
}

// A cycle of links opens nothing now. Loam cannot say what it would open if the
// run could change it, so it gives an error, and the caller refuses.
func TestWritePathOfGivesAnErrorOnACycleOfLinks(t *testing.T) {
	root := realTemp(t)
	a, b := filepath.Join(root, "a"), filepath.Join(root, "b")
	if err := os.Symlink(b, a); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(a, b); err != nil {
		t.Fatal(err)
	}
	if _, err := (Rules{}).WritePathOf(a); err == nil || !strings.Contains(err.Error(), "links") {
		t.Errorf("WritePathOf of a cycle: %v, want an error about links", err)
	}
	if _, err := (Rules{}).WritePathOf("relative/path"); err == nil {
		t.Error("WritePathOf of a relative path gives no error")
	}
}
