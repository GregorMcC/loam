package sandbox

import (
	"slices"
	"strings"
	"testing"
)

// TAS-175: a path of the settings is absolute or starts with ~/. It must not
// open home, and Loam keeps the text in the form that the user gave.
func TestCheckPath(t *testing.T) {
	home := realTemp(t)
	good := map[string]string{
		"~/.nvm":                      "~/.nvm",
		"~/.nvm/":                     "~/.nvm",
		"~/a/../b":                    "~/b",
		home + "/Library/Caches/Loam": "~/Library/Caches/Loam",
		"/opt/homebrew":               "/opt/homebrew",
		"/opt/../usr/local":           "/usr/local",
		"~/.cargo/registry":           "~/.cargo/registry",
	}
	for in, want := range good {
		if got, err := CheckPath(home, in); err != nil || got != want {
			t.Errorf("CheckPath(%q) = %q, %v, want %q", in, got, err, want)
		}
	}
	bad := []string{
		"", "   ", "relative/dir", "~", "~other/x", ".",
		home, home + "/", "~/", "/", filepathAbove(home),
		"~/.ssh", "~/.ssh/keys", "~/.config/gh/hosts.yml", "~/.AWS",
		"~/.config", // holds ~/.config/gh
		"~/.cargo",  // holds ~/.cargo/credentials.toml
		"~/..",      // above home
		"~/.nvm/*", "~/.nvm/[a]", "~/.nvm/?", "~/.{nvm,ssh}",
		"~/a\nb", "~/a\x00b", "~/a\"b",
		"~/.loam", "~/.loam/loam.db", "~/.claude", "~/.claude/settings.json", // the settings of Loam and Claude Code
		"/System/Volumes/Data" + home + "/.ssh", // the firmlink of the same folder
		"/srv/loam", "/srv/loam/plots", "/srv",  // a Loam home elsewhere, passed as protected
	}
	for _, in := range bad {
		if got, err := CheckPath(home, in, "/srv/loam"); err == nil {
			t.Errorf("CheckPath(%q) = %q, want an error", in, got)
		}
	}
}

func filepathAbove(home string) string { return home[:strings.LastIndex(home, "/")] }

func TestCheckHost(t *testing.T) {
	good := map[string]string{
		"example.com":        "example.com",
		"Example.COM":        "example.com",
		"*.example.com":      "*.example.com",
		"registry.npmjs.org": "registry.npmjs.org",
		"a-b.example.co.uk":  "a-b.example.co.uk",
		" example.com ":      "example.com",
	}
	for in, want := range good {
		if got, err := CheckHost(in); err != nil || got != want {
			t.Errorf("CheckHost(%q) = %q, %v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{
		"", "*", "*.", "*.com", "localhost", "intranet", "127.0.0.1", "10.0.0.1", "*.0.1", "169.254.169.254", "::1", "[::1]", "**.example.com", "a.*.example.com", "*example.com", "ex*.example.com",
		"https://example.com", "example.com/path", "example.com:443", "user@example.com", "example.com.",
		".example.com", "a..b.com", "-a.com", "a-.com", "a b.com", "exämple.com", "a_b.com",
		strings.Repeat("a", 64) + ".com", strings.Repeat("a.", 130) + "com",
	} {
		if got, err := CheckHost(in); err == nil {
			t.Errorf("CheckHost(%q) = %q, want an error", in, got)
		}
	}
}

// The rules add the machine settings and the plot settings. A write path is
// also a read path. A value that the check refuses is left out, because the
// store can hold a value that an older version wrote.
func TestForAddsTheSettings(t *testing.T) {
	dir := realTemp(t)
	home := dir + "/home"
	got := mustFor(t, Input{
		Home:   home,
		Folder: dir + "/work",
		GitDir: dir + "/repo/.git",
		Getenv: noEnv,
		Machine: Extra{
			Read:  []string{"~/.nvm", "/opt/homebrew"},
			Write: []string{"~/Library/Caches/Loam"},
			Hosts: []string{"registry.example.com"},
		},
		Plot: Extra{
			Read:  []string{"~/notes", "~/.nvm"},
			Write: []string{"~/out"},
			Hosts: []string{"*.example.org", "Registry.Example.com"},
		},
	})
	for _, p := range []string{home + "/.nvm", "/opt/homebrew", home + "/Library/Caches/Loam", home + "/notes", home + "/out"} {
		if !slices.Contains(got.Read, p) {
			t.Errorf("Read lacks %q: %q", p, got.Read)
		}
	}
	for _, p := range []string{home + "/Library/Caches/Loam", home + "/out"} {
		if !slices.Contains(got.Write, p) {
			t.Errorf("Write lacks %q: %q", p, got.Write)
		}
	}
	for _, p := range []string{home + "/.nvm", "/opt/homebrew", home + "/notes"} {
		if slices.Contains(got.Write, p) {
			t.Errorf("Write has the read path %q: %q", p, got.Write)
		}
	}
	if want := []string{"registry.example.com", "*.example.org"}; !slices.Equal(got.Hosts, want) {
		t.Errorf("Hosts = %q, want %q", got.Hosts, want)
	}
	if n := strings.Count(strings.Join(got.Read, "\n"), home+"/.nvm"); n != 1 {
		t.Errorf("~/.nvm is in Read %d times: %q", n, got.Read)
	}
}

func TestForLeavesOutASettingThatOpensHome(t *testing.T) {
	dir := realTemp(t)
	home := dir + "/home"
	bad := Extra{
		Read:  []string{"~", "/", "~/.ssh", "~/.config", "relative", "~/*", dir, "~/.loam", "~/.claude/x", "/srv/loam"},
		Write: []string{"~/", "~/.aws/x", "~/a\nb"},
		Hosts: []string{"*", "https://example.com", "*.com", "", "localhost", "127.0.0.1"},
	}
	got := mustFor(t, Input{Home: home, Folder: dir + "/work", GitDir: dir + "/repo/.git", Getenv: noEnv, Machine: bad, Plot: bad, Protected: []string{"/srv/loam"}})
	want := mustFor(t, Input{Home: home, Folder: dir + "/work", GitDir: dir + "/repo/.git", Getenv: noEnv})
	if !slices.Equal(got.Read, want.Read) || !slices.Equal(got.Write, want.Write) || !slices.Equal(got.Hosts, want.Hosts) {
		t.Errorf("rules changed:\n got %+v\nwant %+v", got, want)
	}
}
