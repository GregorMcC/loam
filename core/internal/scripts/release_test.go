package scripts_test

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// adhocRequirement replaces the pinned certificate in the tests, because the
// fake releases are signed ad hoc.
const adhocRequirement = `identifier "dev.loam.Loam"`

func pinnedCert(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(script(name))
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`certificate leaf = H\\?"([0-9a-f]{40})\\?"`).FindStringSubmatch(string(b))
	if m == nil {
		t.Fatalf("%s pins no certificate", name)
	}
	return m[1]
}

func TestReleaseAndInstallPinTheSameCertificate(t *testing.T) {
	if a, b := pinnedCert(t, "release.sh"), pinnedCert(t, "install-release.sh"); a != b {
		t.Fatalf("release.sh pins %s, install-release.sh pins %s", a, b)
	}
}

// fakeRelease writes a release of version into dir, as GitHub serves it:
// latest/download/Loam.zip and download/<version>/Loam.zip, each with a
// .sha256. The app inside is signed ad hoc and holds a loam CLI that prints
// the version, in Contents/Helpers as in a real release.
func fakeRelease(t *testing.T, dir, version string) {
	t.Helper()
	if runtime.GOOS != "darwin" {
		t.Skip("releases install on macOS only")
	}
	build := t.TempDir()
	macos := filepath.Join(build, "Loam.app", "Contents", "MacOS")
	helpers := filepath.Join(build, "Loam.app", "Contents", "Helpers")
	for _, d := range []string{macos, helpers} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		filepath.Join(macos, "Loam"): "#!/bin/sh\nexit 0\n",
		filepath.Join(helpers, "loam"): "#!/bin/sh\necho loam version " + version + "\n",
		filepath.Join(build, "Loam.app", "Contents", "Info.plist"): `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Loam</string>
<key>CFBundleIdentifier</key><string>dev.loam.Loam</string>
<key>LoamVersion</key><string>` + version + `</string>
</dict></plist>
`,
	}
	for path, body := range files {
		if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	app := filepath.Join(build, "Loam.app")
	for _, target := range []string{filepath.Join(helpers, "loam"), app} {
		if out, err := exec.Command("codesign", "--force", "--sign", "-", target).CombinedOutput(); err != nil {
			t.Fatalf("codesign: %v: %s", err, out)
		}
	}
	zip := filepath.Join(build, "Loam.zip")
	if out, err := exec.Command("ditto", "-c", "-k", "--keepParent", app, zip).CombinedOutput(); err != nil {
		t.Fatalf("ditto: %v: %s", err, out)
	}
	data, err := os.ReadFile(zip)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	for _, sub := range []string{filepath.Join("latest", "download"), filepath.Join("download", version)} {
		d := filepath.Join(dir, sub)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "Loam.zip"), data, 0o644); err != nil {
			t.Fatal(err)
		}
		line := fmt.Sprintf("%s  Loam.zip\n", hex.EncodeToString(sum[:]))
		if err := os.WriteFile(filepath.Join(d, "Loam.zip.sha256"), []byte(line), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

type releaseRig struct {
	releases, apps, prefix, home string
	env                          []string
}

func newReleaseRig(t *testing.T) *releaseRig {
	t.Helper()
	r := &releaseRig{releases: t.TempDir(), apps: t.TempDir(), prefix: t.TempDir(), home: t.TempDir()}
	r.env = []string{
		"LOAM_RELEASES_URL=file://" + r.releases,
		"LOAM_RELEASE_REQUIREMENT=" + adhocRequirement,
		"HOME=" + r.home,
	}
	return r
}

// run runs install-release.sh through sh, as curl | sh does.
func (r *releaseRig) run(t *testing.T, path string, args ...string) (string, error) {
	t.Helper()
	args = append([]string{script("install-release.sh"), "--prefix", r.prefix, "--apps-dir", r.apps}, args...)
	cmd := exec.Command("/bin/sh", args...)
	cmd.Env = append(os.Environ(), r.env...)
	if path != "" {
		cmd.Env = append(cmd.Env, "PATH="+path)
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (r *releaseRig) installedVersion(t *testing.T) string {
	t.Helper()
	out, err := exec.Command(filepath.Join(r.prefix, "bin", "loam")).CombinedOutput()
	if err != nil {
		t.Fatalf("installed loam: %v: %s", err, out)
	}
	return strings.TrimSpace(strings.TrimPrefix(string(out), "loam version "))
}

// noStage fails when a staging folder is left in the apps folder.
func (r *releaseRig) noStage(t *testing.T) {
	t.Helper()
	entries, _ := os.ReadDir(r.apps)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".Loam.") {
			t.Errorf("staging folder left: %s", e.Name())
		}
	}
}

func TestInstallReleaseInstallsAppAndLinksCLI(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	out, err := r.run(t, "")
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	link := filepath.Join(r.prefix, "bin", "loam")
	target, err := os.Readlink(link)
	if want := filepath.Join(r.apps, "Loam.app", "Contents", "Helpers", "loam"); err != nil || target != want {
		t.Fatalf("link %s -> %q (%v), want %q", link, target, err, want)
	}
	if v := r.installedVersion(t); v != "v0.1.0" {
		t.Errorf("installed %q", v)
	}
	if !strings.Contains(out, "loam setup") {
		t.Errorf("a first install must name loam setup: %s", out)
	}
	r.noStage(t)
}

func TestInstallReleaseDoesNothingForTheSameVersion(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	if out, err := r.run(t, ""); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	// A loam from a source install takes the place of the link.
	link := filepath.Join(r.prefix, "bin", "loam")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(link, []byte("#!/bin/sh\necho loam version dev\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	out, err := r.run(t, "")
	if err != nil || !strings.Contains(out, "Loam v0.1.0 is installed") {
		t.Fatalf("want nothing to do, got %v: %s", err, out)
	}
	if v := r.installedVersion(t); v != "v0.1.0" {
		t.Errorf("the same version must still link the CLI in Loam.app, got %q", v)
	}
	r.noStage(t)
}

func TestInstallReleaseUpdatesAndPinsAVersion(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	if out, err := r.run(t, ""); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	fakeRelease(t, r.releases, "v0.2.0")
	out, err := r.run(t, "")
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if v := r.installedVersion(t); v != "v0.2.0" {
		t.Errorf("after update: %q", v)
	}
	if strings.Contains(out, "loam setup") {
		t.Errorf("an update must not ask for loam setup again: %s", out)
	}
	// --version installs that release, also an older one.
	if out, err := r.run(t, "", "--version", "v0.1.0"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if v := r.installedVersion(t); v != "v0.1.0" {
		t.Errorf("after --version v0.1.0: %q", v)
	}
	r.noStage(t)
}

func TestInstallReleaseRejectsBadChecksum(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	bad := strings.Repeat("0", 64) + "  Loam.zip\n"
	if err := os.WriteFile(filepath.Join(r.releases, "latest", "download", "Loam.zip.sha256"), []byte(bad), 0o644); err != nil {
		t.Fatal(err)
	}
	out, err := r.run(t, "")
	if err == nil || !strings.Contains(out, "checksum") {
		t.Fatalf("want checksum failure, got %v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(r.apps, "Loam.app")); !os.IsNotExist(err) {
		t.Error("Loam.app installed despite a bad checksum")
	}
	r.noStage(t)
}

func TestInstallReleaseRejectsAnotherSignature(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	r.env = append(r.env, "LOAM_RELEASE_REQUIREMENT=") // the pinned certificate
	out, err := r.run(t, "")
	if err == nil || !strings.Contains(out, "signature") {
		t.Fatalf("want signature failure, got %v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(r.apps, "Loam.app")); !os.IsNotExist(err) {
		t.Error("Loam.app installed despite another signature")
	}
	if _, err := os.Lstat(filepath.Join(r.prefix, "bin", "loam")); !os.IsNotExist(err) {
		t.Error("loam linked despite another signature")
	}
	r.noStage(t)
}

func TestInstallReleaseRejectsOldMacOS(t *testing.T) {
	r := newReleaseRig(t)
	out, err := r.run(t, fakeTools(t, map[string]string{"sw_vers": "echo 15.5"}))
	if err == nil || !strings.Contains(out, "macOS 26") {
		t.Fatalf("want macOS failure, got %v: %s", err, out)
	}
}

func TestInstallReleaseRejectsIntel(t *testing.T) {
	r := newReleaseRig(t)
	out, err := r.run(t, fakeTools(t, map[string]string{"sysctl": "echo 0"}))
	if err == nil || !strings.Contains(out, "Apple silicon") {
		t.Fatalf("want Apple silicon failure, got %v: %s", err, out)
	}
}

// With Loam running, the install quits Loam, installs, and opens Loam again,
// from a process that outlives the terminal.
func TestInstallReleaseReplacesRunningLoam(t *testing.T) {
	r := newReleaseRig(t)
	fakeRelease(t, r.releases, "v0.1.0")
	state := t.TempDir()
	quit, opened := filepath.Join(state, "quit"), filepath.Join(state, "opened")
	path := fakeTools(t, map[string]string{
		// Loam runs until osascript asks it to quit.
		"pgrep":     fmt.Sprintf(`[ ! -f %q ]`, quit),
		"osascript": fmt.Sprintf(`touch %q`, quit),
		"open":      fmt.Sprintf(`echo "$@" > %q`, opened),
	})
	out, err := r.run(t, path)
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if v := r.installedVersion(t); v != "v0.1.0" {
		t.Errorf("installed %q", v)
	}
	b, err := os.ReadFile(opened)
	if err != nil || strings.TrimSpace(string(b)) != filepath.Join(r.apps, "Loam.app") {
		t.Errorf("want Loam opened again, got %q (%v): %s", b, err, out)
	}
	if !strings.Contains(out, "Reopened Loam") {
		t.Errorf("output lacks the log: %s", out)
	}
	r.noStage(t)
}

func TestReleaseRejectsBadTag(t *testing.T) {
	out, err := exec.Command(script("release.sh"), "1.0").CombinedOutput()
	if err == nil || !strings.Contains(string(out), "usage") {
		t.Fatalf("want usage, got %v: %s", err, out)
	}
}

func TestReleaseNeedsTheLoamCertificate(t *testing.T) {
	cmd := exec.Command(script("release.sh"), "v9.9.9", "--dry-run")
	cmd.Env = append(os.Environ(), "PATH="+fakeTools(t, map[string]string{"security": "echo '     0 valid identities found'"}))
	out, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(out), "Loam Local Signing") || !strings.Contains(string(out), "Fix:") {
		t.Fatalf("want certificate failure with fix, got %v: %s", err, out)
	}
}
