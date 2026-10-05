package linkkind

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// fakeOpen puts a script in place of /usr/bin/open. The script writes each
// call to a log, one line per call with the arguments joined by a tab. When
// noObsidian is true, it logs an obsidian:// call and exits 1, as macOS open
// does when no app handles the scheme.
func fakeOpen(t *testing.T, noObsidian bool) (log string) {
	t.Helper()
	dir := t.TempDir()
	log = filepath.Join(dir, "calls.log")
	script := "#!/bin/sh\n" +
		"IFS=\"$(printf '\\t')\"\n"
	if noObsidian {
		script += "case \"$1\" in obsidian://*) echo \"$*\" >> \"" + log + "\"; exit 1;; esac\n"
	}
	script += "if [ -n \"$LOAM_FAKE_OPEN_FAIL\" ]; then echo boom >&2; exit 3; fi\n" +
		"echo \"$*\" >> \"" + log + "\"\n"
	bin := filepath.Join(dir, "open")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_OPEN", bin)
	return log
}

func calls(t *testing.T, log string) [][]string {
	t.Helper()
	b, err := os.ReadFile(log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out [][]string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		out = append(out, strings.Split(l, "\t"))
	}
	return out
}

func TestOpenEachTarget(t *testing.T) {
	root := t.TempDir()
	vault := filepath.Join(root, "My Vault")
	if err := os.MkdirAll(filepath.Join(vault, "notes"), 0o755); err != nil {
		t.Fatal(err)
	}
	vfile := filepath.Join(vault, "notes", "a b+c.md")
	plainDir := filepath.Join(root, "plain")
	plainFile := filepath.Join(root, "plain.txt")
	if err := os.Mkdir(plainDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{vfile, plainFile} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	vaults := []string{vault}
	// Obsidian wants %20 for a space, %2F for a slash, and %2B for a plus.
	wantURI := "obsidian://open?path=" + strings.NewReplacer("/", "%2F", " ", "%20", "+", "%2B").Replace(vfile)

	for _, c := range []struct {
		name       string
		target     string
		noObsidian bool
		via        string
		want       [][]string
	}{
		{"notion", "https://www.notion.so/Loam-1", false, ViaBrowser, [][]string{{"https://www.notion.so/Loam-1"}}},
		{"linear", "https://linear.app/a/issue/B-1", false, ViaBrowser, [][]string{{"https://linear.app/a/issue/B-1"}}},
		{"github", "https://github.com/a/b", false, ViaBrowser, [][]string{{"https://github.com/a/b"}}},
		{"url", "https://example.com", false, ViaBrowser, [][]string{{"https://example.com"}}},
		{"other scheme", "mailto:a@b.c", false, ViaDefaultApp, [][]string{{"mailto:a@b.c"}}},
		{"vault file", vfile, false, ViaObsidian, [][]string{{wantURI}}},
		{"vault file without Obsidian", vfile, true, ViaDefaultApp, [][]string{{wantURI}, {vfile}}},
		{"vault folder", filepath.Join(vault, "notes"), false, ViaFinder, [][]string{{filepath.Join(vault, "notes")}}},
		{"vault root", vault, false, ViaFinder, [][]string{{vault}}},
		{"plain folder", plainDir, false, ViaFinder, [][]string{{plainDir}}},
		{"plain file", plainFile, false, ViaDefaultApp, [][]string{{plainFile}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			log := fakeOpen(t, c.noObsidian)
			via, err := Open(Classify(c.target, vaults))
			if err != nil {
				t.Fatal(err)
			}
			if via != c.via {
				t.Errorf("via %q, want %q", via, c.via)
			}
			if got := calls(t, log); !reflect.DeepEqual(got, c.want) {
				t.Errorf("calls %q, want %q", got, c.want)
			}
		})
	}
}

func TestOpenRejectsOtherSchemes(t *testing.T) {
	log := fakeOpen(t, false)
	for _, target := range []string{"file:///etc/hosts", "shortcuts://run-shortcut?name=x", "x-apple.systempreferences:com.apple.preference", "vscode://file/tmp", "javascript:alert(1)"} {
		_, err := Open(Classify(target, nil))
		if !errors.Is(err, ErrScheme) {
			t.Errorf("Open(%q) err %v, want ErrScheme", target, err)
		}
	}
	if got := calls(t, log); got != nil {
		t.Errorf("open ran: %q", got)
	}
}

func TestOpenAllowsSchemesInAnyCase(t *testing.T) {
	log := fakeOpen(t, false)
	via, err := Open(Classify("HTTPS://Example.com/x", nil))
	if err != nil || via != ViaBrowser {
		t.Fatalf("via %q, err %v", via, err)
	}
	if got := calls(t, log); !reflect.DeepEqual(got, [][]string{{"HTTPS://Example.com/x"}}) {
		t.Errorf("calls %q", got)
	}
}

// A file or a bundle that open would run is revealed in Finder, so a link
// that a session added cannot run code when you click it.
func TestOpenRevealsWhatWouldRun(t *testing.T) {
	root := t.TempDir()
	vault := filepath.Join(root, "vault")
	app := filepath.Join(root, "Evil.app")
	bundle := filepath.Join(root, "Plain")
	if err := os.MkdirAll(filepath.Join(app, "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(bundle, "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(vault, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "Contents", "Info.plist"), []byte("<plist/>"), 0o644); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(root, "run")
	command := filepath.Join(root, "Setup.command")
	vaultExe := filepath.Join(vault, "note.md")
	for p, mode := range map[string]os.FileMode{exe: 0o755, command: 0o644, vaultExe: 0o700} {
		if err := os.WriteFile(p, []byte("#!/bin/sh\n"), mode); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		name, target string
	}{
		{"app bundle", app},
		{"bundle with Info.plist", bundle},
		{"executable file", exe},
		{"command file", command},
		{"executable in a vault", vaultExe},
	} {
		t.Run(c.name, func(t *testing.T) {
			log := fakeOpen(t, false)
			via, err := Open(Classify(c.target, []string{vault}))
			if err != nil {
				t.Fatal(err)
			}
			if via != ViaFinder {
				t.Errorf("via %q, want %q", via, ViaFinder)
			}
			if got := calls(t, log); !reflect.DeepEqual(got, [][]string{{"-R", c.target}}) {
				t.Errorf("calls %q, want reveal", got)
			}
		})
	}
}

func TestOpenMissingPathRunsNothing(t *testing.T) {
	log := fakeOpen(t, false)
	info := Classify(filepath.Join(t.TempDir(), "gone"), nil)
	if _, err := Open(info); err != ErrMissing {
		t.Fatalf("err %v, want ErrMissing", err)
	}
	if got := calls(t, log); got != nil {
		t.Errorf("open ran: %q", got)
	}
}

func TestOpenRejectsTargetWithoutScheme(t *testing.T) {
	log := fakeOpen(t, false)
	for _, target := range []string{"notes.md", "-a Calculator", "relative/path", ""} {
		if _, err := Open(Classify(target, nil)); err == nil || !strings.Contains(err.Error(), "not a URL") {
			t.Errorf("Open(%q) err %v", target, err)
		}
	}
	if got := calls(t, log); got != nil {
		t.Errorf("open ran: %q", got)
	}
}

func TestOpenReportsFailure(t *testing.T) {
	fakeOpen(t, false)
	t.Setenv("LOAM_FAKE_OPEN_FAIL", "1")
	_, err := Open(Classify("https://example.com", nil))
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("err %v", err)
	}
}

func TestOpenDefaultCommand(t *testing.T) {
	t.Setenv("LOAM_OPEN", "")
	if got := openBin(); got != "/usr/bin/open" {
		t.Errorf("default %q", got)
	}
}
