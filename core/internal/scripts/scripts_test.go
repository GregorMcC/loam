package scripts_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func script(name string) string {
	p, _ := filepath.Abs(filepath.Join("..", "..", "..", "scripts", name))
	return p
}

func TestInstallCoreToTempPrefix(t *testing.T) {
	prefix := t.TempDir()
	out, err := exec.Command(script("install.sh"), "core", "--prefix", prefix).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	bin := filepath.Join(prefix, "bin", "loam")
	v, err := exec.Command(bin, "version").CombinedOutput()
	if err != nil || !strings.HasPrefix(string(v), "loam version ") {
		t.Fatalf("installed binary: %v %q", err, v)
	}
	// Run again: the install replaces the binary and leaves no temp file.
	if out, err := exec.Command(script("install.sh"), "core", "--prefix", prefix).CombinedOutput(); err != nil {
		t.Fatalf("second run: %v: %s", err, out)
	}
	entries, _ := os.ReadDir(filepath.Join(prefix, "bin"))
	if len(entries) != 1 {
		t.Errorf("want only loam in bin, got %v", entries)
	}
}

// fakeTools returns a PATH that puts fake commands (name -> shell body) first.
func fakeTools(t *testing.T, tools map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range tools {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir + ":" + os.Getenv("PATH")
}

func installApp(t *testing.T, path string, args ...string) (string, error) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("the app installs on macOS only")
	}
	args = append([]string{"app", "--prefix", t.TempDir(), "--apps-dir", t.TempDir()}, args...)
	cmd := exec.Command(script("install.sh"), args...)
	cmd.Env = append(os.Environ(), "PATH="+path, "LOAM_CACHE="+t.TempDir())
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func TestBuildIconMakesTheAppIcon(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the icon builds on macOS only")
	}
	if err := exec.Command("xcrun", "--find", "actool").Run(); err != nil {
		t.Skip("actool is not installed")
	}
	testutil.SkipInSandbox(t, "actool needs the CoreSimulator services")
	out := t.TempDir()
	if b, err := exec.Command(script("build-icon.sh"), out).CombinedOutput(); err != nil {
		t.Fatalf("build-icon.sh: %v\n%s", err, b)
	}
	for _, name := range []string{"Assets.car", "AppIcon.icns"} {
		if info, err := os.Stat(filepath.Join(out, name)); err != nil || info.Size() == 0 {
			t.Errorf("%s is missing or empty: %v", name, err)
		}
	}
}

func TestInfoPlistNamesTheAppIcon(t *testing.T) {
	b, err := os.ReadFile(script("Info.plist"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"<key>CFBundleIconFile</key><string>AppIcon</string>",
		"<key>CFBundleIconName</key><string>AppIcon</string>",
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("Info.plist lacks %s", want)
		}
	}
}

func TestInstallAppStopsWithoutCertificate(t *testing.T) {
	path := fakeTools(t, map[string]string{"security": "echo '     0 valid identities found'"})
	out, err := installApp(t, path)
	if err == nil {
		t.Fatalf("want failure, got: %s", out)
	}
	for _, want := range []string{"Apple Development", "Xcode", "Accounts", "--adhoc"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q: %s", want, out)
		}
	}
}

func TestInstallAppRejectsOldXcode(t *testing.T) {
	path := fakeTools(t, map[string]string{"xcodebuild": "echo 'Xcode 26.4'; echo 'Build version 1'"})
	out, err := installApp(t, path, "--adhoc")
	if err == nil || !strings.Contains(out, "Xcode 26.5") || !strings.Contains(out, "Fix:") {
		t.Fatalf("want failure with fix, got %v: %s", err, out)
	}
}

func TestInstallAppRejectsMissingMetalToolchain(t *testing.T) {
	path := fakeTools(t, map[string]string{"xcrun": "exit 1"})
	out, err := installApp(t, path, "--adhoc")
	if err == nil || !strings.Contains(out, "Metal Toolchain") || !strings.Contains(out, "downloadComponent MetalToolchain") {
		t.Fatalf("want failure with fix, got %v: %s", err, out)
	}
}

func TestInstallAppAsksToQuitRunningLoam(t *testing.T) {
	path := fakeTools(t, map[string]string{"pgrep": "echo 123"})
	out, err := installApp(t, path, "--adhoc")
	if err == nil || !strings.Contains(out, "Quit Loam") {
		t.Fatalf("want quit request, got %v: %s", err, out)
	}
}

// askThenQuit is a fake osascript for a Loam that asks first: the quit request
// fails at once with the error code, and Loam quits a second later, when you
// choose Quit. The background step leaves the output, so the request returns
// at once and the script must wait for the quit.
func askThenQuit(quit, code string) string {
	return fmt.Sprintf(`(sleep 1; touch %q) >/dev/null 2>&1 &
echo 'Loam got an error: User canceled. (%s)' >&2
exit 1`, quit, code)
}

// waitCases are the quit request errors after which the install waits for
// Loam to quit, with the line that the install prints for each. Both install
// scripts use them.
var waitCases = []struct{ code, says string }{
	{"-128", "If you choose Cancel"},
	{"-1712", "did not answer yet"},
	{"-600", "Loam is quitting"},
	{"-609", "Loam is quitting"},
}

// stopCases are quit request errors that stop the install while Loam runs,
// with the text that the stop must show.
var stopCases = []struct{ stderr, want string }{
	{"echo 'Not authorized to send Apple events to Loam. (-1743)' >&2", "(-1743)"},
	{"", "no error text"},
}

// The two install scripts keep their own copy of the quit step, because
// install-release.sh must run alone. The copies handle the same errors.
func TestBothQuitStepsHandleTheSameErrors(t *testing.T) {
	steps := make([]string, 2)
	for i, name := range []string{"install.sh", "install-release.sh"} {
		b, err := os.ReadFile(script(name))
		if err != nil {
			t.Fatal(err)
		}
		s := string(b)
		start := strings.Index(s, `case "$err" in`)
		end := strings.Index(s[max(start, 0):], "esac")
		if start < 0 || end < 0 {
			t.Fatalf("%s has no quit step", name)
		}
		steps[i] = strings.NewReplacer("scripts/update.sh again", "", "the install again", "").Replace(s[start : start+end])
	}
	if steps[0] != steps[1] {
		t.Errorf("the quit steps differ:\ninstall.sh:\n%s\ninstall-release.sh:\n%s", steps[0], steps[1])
	}
}

// runningUntil is a fake pgrep: Loam runs until the file quit exists. Each call
// while Loam runs adds a line to calls.
func runningUntil(quit, calls string) string {
	return fmt.Sprintf(`[ ! -f %q ] || exit 1
echo >> %q`, quit, calls)
}

// lineCount is the number of lines in the file, or 0 when it is missing.
func lineCount(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return strings.Count(string(b), "\n")
}

// fakeBuildApp stands in for build-app.sh: it makes OUT/Loam.app with only an
// Info.plist that names the version.
const fakeBuildApp = `#!/bin/sh
mkdir -p "$1/Loam.app/Contents"
cat > "$1/Loam.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>LoamVersion</key><string>v9.9.9</string></dict></plist>
PLIST
`

// replaceRig is a copy of install.sh in a temp repo, with the real core and a
// fake build-app.sh, so --replace-running runs without an app build.
func replaceRig(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	core, err := filepath.Abs(filepath.Join("..", "..", "..", "core"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(core, filepath.Join(root, "core")); err != nil {
		t.Fatal(err)
	}
	scripts := filepath.Join(root, "scripts")
	if err := os.Mkdir(scripts, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(script("install.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "install.sh"), b, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(scripts, "build-app.sh"), []byte(fakeBuildApp), 0o755); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(scripts, "install.sh")
}

// replace runs the copy of install.sh with --replace-running and the fake tools.
func replace(t *testing.T, apps string, tools map[string]string) (string, error) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("the app installs on macOS only")
	}
	cmd := exec.Command(replaceRig(t), "app", "--prefix", t.TempDir(), "--apps-dir", apps, "--adhoc", "--replace-running")
	cmd.Env = append(os.Environ(), "PATH="+fakeTools(t, tools))
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// Loam asks first when a session is mid-turn, and answers the quit request
// with "User canceled" (-128). A busy Loam can let the request time out
// (-1712), and a Loam that quits already can miss it (-600, -609). The
// install waits and goes on when Loam quits.
func TestInstallAppReplaceWaitsWhileLoamAsks(t *testing.T) {
	for _, c := range waitCases {
		t.Run(c.code, func(t *testing.T) {
			quit, calls := filepath.Join(t.TempDir(), "quit"), filepath.Join(t.TempDir(), "calls")
			apps := t.TempDir()
			out, err := replace(t, apps, map[string]string{
				"pgrep":     runningUntil(quit, calls),
				"osascript": askThenQuit(quit, c.code),
				"open":      "true",
			})
			if err != nil {
				t.Fatalf("%v: %s", err, out)
			}
			if _, err := os.Stat(filepath.Join(apps, "Loam.app", "Contents", "Info.plist")); err != nil {
				t.Errorf("no app installed: %v: %s", err, out)
			}
			for _, want := range []string{"choose Quit", c.says, "Reopened Loam"} {
				if !strings.Contains(out, want) {
					t.Errorf("output lacks %q: %s", want, out)
				}
			}
			// One check before the quit request, then at least one in the wait.
			if n := lineCount(t, calls); n < 2 {
				t.Errorf("the install did not wait: pgrep saw Loam %d times: %s", n, out)
			}
		})
	}
}

// Any failed request changes nothing when Loam is gone after it: the install
// goes on.
func TestInstallAppReplaceGoesOnWhenLoamIsGone(t *testing.T) {
	quit, calls := filepath.Join(t.TempDir(), "quit"), filepath.Join(t.TempDir(), "calls")
	apps := t.TempDir()
	out, err := replace(t, apps, map[string]string{
		"pgrep":     runningUntil(quit, calls),
		"osascript": fmt.Sprintf(`touch %q; echo "Loam got an error: Some other error. (-1708)" >&2; exit 1`, quit),
		"open":      "true",
	})
	if err != nil || strings.Contains(out, "Could not ask") {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(apps, "Loam.app", "Contents", "Info.plist")); err != nil {
		t.Errorf("no app installed: %v: %s", err, out)
	}
}

// Any other failure of the quit request stops the install at once, with the
// error, and installs nothing. An error with no text says so.
func TestInstallAppReplaceStopsWhenTheQuitRequestFails(t *testing.T) {
	for _, c := range stopCases {
		t.Run(c.want, func(t *testing.T) {
			apps := t.TempDir()
			out, err := replace(t, apps, map[string]string{
				"pgrep":     "true",
				"osascript": c.stderr + "\nexit 1",
			})
			if err == nil || !strings.Contains(out, c.want) || strings.Contains(out, "waits up to") {
				t.Fatalf("want a stop with %q, got %v: %s", c.want, err, out)
			}
			if _, err := os.Stat(filepath.Join(apps, "Loam.app")); err == nil {
				t.Errorf("an app was installed: %s", out)
			}
		})
	}
}

// A self-signed "Loam Local Signing" identity passes the certificate step,
// so the install reaches the next check (Loam is running).
func TestInstallAppAcceptsLocalSigningCertificate(t *testing.T) {
	path := fakeTools(t, map[string]string{
		"security": `echo '  1) 72E22E0E1CDB829CFF9A4DE5E84804F49B5D6E18 "Loam Local Signing"'; echo '     1 valid identities found'`,
		"pgrep":    "echo 123",
	})
	out, err := installApp(t, path)
	if err == nil || !strings.Contains(out, "Quit Loam") || strings.Contains(out, "No signing certificate") {
		t.Fatalf("want the certificate step to pass, got %v: %s", err, out)
	}
}

// pinValue reads one KEY=VALUE line from ghostty.pin.
func pinValue(t *testing.T, key string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "ghostty.pin"))
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(line, key+"="); ok {
			return strings.Trim(v, `"`)
		}
	}
	t.Fatalf("ghostty.pin has no %s", key)
	return ""
}

func TestBuildGhosttyKitUsesCacheAndLinksVendor(t *testing.T) {
	cache, vendor := t.TempDir(), filepath.Join(t.TempDir(), "vendor")
	commit := pinValue(t, "GHOSTTY_COMMIT")
	if len(commit) != 40 || pinValue(t, "ZIG_VERSION") == "" || len(pinValue(t, "ZIG_SHA256")) != 64 {
		t.Fatal("ghostty.pin values look wrong")
	}
	cached := filepath.Join(cache, "ghosttykit", commit, "GhosttyKit.xcframework")
	share := filepath.Join(cache, "ghosttykit", commit, "share")
	for _, dir := range []string{cached, filepath.Join(share, "ghostty"), filepath.Join(share, "terminfo")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cmd := exec.Command(script("build-ghosttykit.sh"))
	cmd.Env = append(os.Environ(), "LOAM_CACHE="+cache, "LOAM_VENDOR="+vendor)
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "cached") {
		t.Fatalf("%v: %s", err, out)
	}
	for link, target := range map[string]string{"GhosttyKit.xcframework": cached, "ghostty-share": share} {
		got, err := filepath.EvalSymlinks(filepath.Join(vendor, link))
		want, _ := filepath.EvalSymlinks(target)
		if err != nil || got != want {
			t.Errorf("vendor link %s: got %q want %q (%v)", link, got, want, err)
		}
	}
}

func TestUninstallRemovesApp(t *testing.T) {
	testutil.Home(t)
	testutil.FakeClaude(t)
	apps := t.TempDir()
	if err := os.MkdirAll(filepath.Join(apps, "Loam.app", "Contents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(script("uninstall.sh"), "--prefix", t.TempDir(), "--apps-dir", apps).CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(apps, "Loam.app")); !os.IsNotExist(err) {
		t.Error("Loam.app still there")
	}
}

func TestInstallRejectsOldGo(t *testing.T) {
	dir := t.TempDir()
	fake := "#!/bin/sh\n[ \"$1\" = env ] && echo go1.25.3\n"
	if err := os.WriteFile(filepath.Join(dir, "go"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(script("install.sh"), "core", "--prefix", t.TempDir())
	cmd.Env = append(os.Environ(), "PATH="+dir+":/usr/bin:/bin")
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "Go 1.26") || !strings.Contains(string(out), "Fix:") {
		t.Fatalf("want failure with fix, got %v: %s", err, out)
	}
}

func TestUninstallRemovesBinaryAndRegistration(t *testing.T) {
	home := testutil.Home(t)
	testutil.FakeClaude(t)
	prefix := t.TempDir()
	if err := os.MkdirAll(filepath.Join(prefix, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(prefix, "bin", "loam")
	if err := os.WriteFile(bin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(script("uninstall.sh"), "--prefix", prefix, "--apps-dir", t.TempDir()).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := os.Stat(bin); !os.IsNotExist(err) {
		t.Error("binary still there")
	}
	inv := testutil.FakeClaudeInvocation(t)
	if got := strings.Join(inv.Args, " "); got != "mcp remove --scope user loam" {
		t.Errorf("claude args %q", got)
	}
	if _, err := os.Stat(home); err != nil {
		t.Error("store removed without --purge")
	}
}

func TestUninstallPurgeRemovesStore(t *testing.T) {
	home := testutil.Home(t)
	testutil.FakeClaude(t)
	if out, err := exec.Command(script("uninstall.sh"), "--prefix", t.TempDir(), "--apps-dir", t.TempDir(), "--purge").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := os.Stat(home); !os.IsNotExist(err) {
		t.Error("store still there after --purge")
	}
}
