package scripts_test

import (
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
