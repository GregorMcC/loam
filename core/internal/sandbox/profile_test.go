package sandbox

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func mustProfile(t *testing.T, r Rules, temp string) string {
	t.Helper()
	p, err := r.Profile(temp)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// TAS-175: in SBPL the last rule that matches wins. So the profile denies
// the ways out through other processes, denies the network before it allows
// loopback and the unix sockets below the write paths, denies home before it
// allows the Read paths, denies every write before it allows the write
// paths, and denies the DenyWrite paths last.
func TestProfileOrder(t *testing.T) {
	r := Rules{
		Home:      "/h",
		Read:      []string{"/h/w", "/h/.gitconfig"},
		Write:     []string{"/h/w"},
		DenyWrite: []string{"/h/w/.git/hooks"},
		Hosts:     []string{"proxy.golang.org"},
	}
	const want = `(version 1)
(allow default)
(deny lsopen)
(deny appleevent-send)
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name "com.apple.coreservices.appleevents")
  (global-name "com.apple.CoreServices.coreservicesd")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc"))
(deny signal)
(allow signal (target same-sandbox))
(deny network*)
(allow network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:*"))
(allow network*
  (local unix-socket (subpath "/h/w"))
  (remote unix-socket (subpath "/h/w"))
  (local unix-socket (subpath "/t"))
  (remote unix-socket (subpath "/t")))
(deny file-read*
  (subpath "/h"))
(allow file-read*
  (subpath "/h/w")
  (subpath "/h/.gitconfig")
  (subpath "/t"))
(allow file-read-metadata)
(deny file-write*)
(allow file-write*
  (subpath "/h/w")
  (subpath "/t")
  (subpath "/private/tmp")
  (subpath "/dev"))
(deny file-write*
  (subpath "/h/w/.git/hooks"))
`
	if got := mustProfile(t, r, "/t"); got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
}

// A list with no paths writes no rule: a rule with no filter matches every
// path, so an empty Read would allow all of home.
func TestProfileWritesNoRuleForNoPaths(t *testing.T) {
	got := mustProfile(t, Rules{Home: "/h"}, "")
	for _, rule := range []string{"(allow file-read*", "(deny file-write*\n", "(allow network*"} {
		if strings.Contains(got, rule) {
			t.Errorf("a rule with no paths: %q in\n%s", rule, got)
		}
	}
	if !strings.Contains(got, "(deny file-write*)\n(allow file-write*\n  (subpath \"/private/tmp\")\n  (subpath \"/dev\"))\n") {
		t.Errorf("the profile allows more writes than the temp folders:\n%s", got)
	}
}

// With no home, the profile would deny nothing.
func TestProfileNeedsTheHome(t *testing.T) {
	if _, err := (Rules{Read: []string{"/w"}}).Profile("/t"); err == nil {
		t.Fatal("a profile with no home")
	}
}

// A temp folder that would open home stays out of the profile.
func TestProfileLeavesOutATempThatOpensHome(t *testing.T) {
	none := mustProfile(t, Rules{Home: "/h"}, "")
	for _, temp := range []string{"/h", "/", "/h/.ssh/x"} {
		if got := mustProfile(t, Rules{Home: "/h"}, temp); got != none {
			t.Errorf("temp %s is in the profile:\n%s", temp, got)
		}
	}
}

// TAS-175: a path cannot end its string literal or add a rule. Each quote,
// backslash, and control character is escaped.
func TestProfileQuotesEachPath(t *testing.T) {
	cases := map[string]string{
		`/h/a"b`:                                `"/h/a\"b"`,
		`/h/a\b`:                                `"/h/a\\b"`,
		"/h/a\nb":                               `"/h/a\nb"`,
		"/h/a\r\tb":                             `"/h/a\r\tb"`,
		"/h/a\x01\x7fb":                         `"/h/a\x01\x7fb"`,
		"/h/é":                                  `"/h/é"`,
		`/h/x")) (allow file-read* (subpath "/`: `"/h/x\")) (allow file-read* (subpath \"/"`,
	}
	for path, want := range cases {
		if got := quote(path); got != want {
			t.Errorf("quote(%q) = %s, want %s", path, got, want)
		}
		profile := mustProfile(t, Rules{Home: "/h", Write: []string{path}}, "")
		if n := strings.Count(profile, "\n(allow "); n != 7 {
			t.Errorf("%q: %d allow rules, want 7:\n%s", path, n, profile)
		}
	}
}

// Writable holds a path in a written folder and each path below one. A
// DenyWrite path does not change it: a check can move a folder above it.
func TestWritable(t *testing.T) {
	r := Rules{Home: "/h", Write: []string{"/h/w"}, DenyWrite: []string{"/h/w/.git/hooks"}}
	cases := map[string]bool{
		"/h/w":                 true,
		"/h/W/x":               true,
		"/h/w/.git/hooks/a.sb": true,
		"/t/a.sb":              true,
		"/private/tmp/a.sb":    true,
		"/h":                   false,
		"/h/.loam/gate.sb":     false,
		"/h/wx":                false,
		"/elsewhere":           false,
	}
	for path, want := range cases {
		if got := r.Writable(path, "/t"); got != want {
			t.Errorf("Writable(%s) = %v, want %v", path, got, want)
		}
	}
}

// sandboxed runs sh -c command under the profile of r and returns its output
// and whether it passed.
func sandboxed(t *testing.T, r Rules, temp, command string) (string, bool) {
	t.Helper()
	return sandboxedIn(t, r, []string{temp}, command)
}

// sandboxedIn is [sandboxed] with several temp folders.
func sandboxedIn(t *testing.T, r Rules, temps []string, command string) (string, bool) {
	t.Helper()
	text, err := r.Profile(temps...)
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "gate.sb")
	if err := os.WriteFile(file, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("/usr/bin/sandbox-exec", "-f", file, "sh", "-c", command).CombinedOutput()
	return string(out), err == nil
}

// boxedHome returns rules for a fake home with a run folder in it, a secret
// file beside it, and a temp folder outside it that is not written.
func boxedHome(t *testing.T) (r Rules, run, secret, outside string) {
	t.Helper()
	testutil.NeedSandbox(t)
	root := realTemp(t)
	home := filepath.Join(root, "home")
	run = filepath.Join(home, "run")
	secret = filepath.Join(home, ".ssh", "id_ed25519")
	outside = filepath.Join(root, "outside")
	mkfile(t, filepath.Join(run, "go.mod"))
	mkfile(t, secret)
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	r = mustFor(t, Input{Home: home, Folder: run, GitDir: filepath.Join(run, ".git"), Repos: []string{run}, Getenv: noEnv})
	return r, run, secret, outside
}

// TAS-175: a check reads the run folder, and not the rest of home.
func TestProfileDeniesReadsOfHome(t *testing.T) {
	r, run, secret, _ := boxedHome(t)
	if out, ok := sandboxed(t, r, "", "cat "+shellQuote(filepath.Join(run, "go.mod"))); !ok {
		t.Fatalf("read of the run folder: %s", out)
	}
	if out, ok := sandboxed(t, r, "", "cat "+shellQuote(secret)); ok || !strings.Contains(out, "Operation not permitted") {
		t.Fatalf("read of %s passed: %s", secret, out)
	}
	// Metadata gives names and sizes, which git needs.
	if out, ok := sandboxed(t, r, "", "test -e "+shellQuote(secret)); !ok {
		t.Fatalf("metadata of home: %s", out)
	}
}

// TAS-175: a check writes the run folder and the temp folder, and nothing
// else. A DenyWrite path wins over the run folder that holds it.
func TestProfileAllowsOnlyTheWritePaths(t *testing.T) {
	r, run, _, outside := boxedHome(t)
	temp := filepath.Join(filepath.Dir(outside), "tmp")
	for _, dir := range []string{temp, filepath.Join(run, ".git", "hooks")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, path := range []string{filepath.Join(run, "out.txt"), filepath.Join(temp, "out.txt"), "/dev/null"} {
		if out, ok := sandboxed(t, r, temp, "echo hi > "+shellQuote(path)); !ok {
			t.Errorf("write of %s: %s", path, out)
		}
	}
	for _, path := range []string{
		filepath.Join(outside, "out.txt"),
		filepath.Join(r.Home, "out.txt"),
		filepath.Join(run, ".git", "hooks", "pre-push"),
	} {
		if out, ok := sandboxed(t, r, temp, "echo hi > "+shellQuote(path)); ok {
			t.Errorf("write of %s passed: %s", path, out)
		}
	}
}

// TAS-175: a folder with a quote, a backslash, or a newline in its name is
// written as itself, and opens no other folder.
func TestProfileQuotesPathsForSandboxExec(t *testing.T) {
	r, _, _, outside := boxedHome(t)
	odd := filepath.Join(outside, "a\"b\\c\nd")
	if err := os.MkdirAll(odd, 0o755); err != nil {
		t.Fatal(err)
	}
	r.Write = append(r.Write, odd)
	if out, ok := sandboxed(t, r, "", "touch "+shellQuote(filepath.Join(odd, "x"))); !ok {
		t.Fatalf("write of the odd folder: %s", out)
	}
	if out, ok := sandboxed(t, r, "", "touch "+shellQuote(filepath.Join(outside, "x"))); ok {
		t.Fatalf("the odd folder opened its parent: %s", out)
	}
}

// netScript runs one network step in python3 and prints "ok" or the error.
const netScript = `import socket, sys
step, arg = sys.argv[1], sys.argv[2]
try:
    if step == "loopback":
        s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
        c = socket.socket(); c.connect(s.getsockname())
    elif step == "host":
        c = socket.socket(); c.settimeout(5); c.connect((arg, 80))
    elif step == "serve":
        s = socket.socket(socket.AF_UNIX); s.bind(arg); s.listen(1)
        c = socket.socket(socket.AF_UNIX); c.connect(arg)
    elif step == "connect":
        c = socket.socket(socket.AF_UNIX); c.connect(arg)
    print("ok")
except OSError as e:
    print(e)
`

// network runs one step of netScript under the profile of r. The temp
// folder of the test is a temp folder of the profile too: the python3 of the
// Xcode tools writes a cache there.
func network(t *testing.T, r Rules, temp, step, arg string) string {
	t.Helper()
	out, _ := sandboxedIn(t, r, []string{temp, os.TempDir()}, "/usr/bin/python3 -I -c "+shellQuote(netScript)+" "+step+" "+shellQuote(arg))
	return strings.TrimSpace(out)
}

// shortTemp returns a new folder in /private/tmp, whose path is short enough
// for a unix socket.
func shortTemp(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/private/tmp", "loam-sb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

// TAS-175: a check runs a loopback server and reaches it, as the test
// servers of Go's httptest do, but reaches no other host. 192.0.2.1 is a
// documentation address: with no sandbox, a connect to it times out.
func TestProfileAllowsOnlyLoopback(t *testing.T) {
	r, _, _, _ := boxedHome(t)
	if got := network(t, r, "", "loopback", ""); got != "ok" {
		t.Fatalf("loopback: %s", got)
	}
	if got := network(t, r, "", "host", "192.0.2.1"); !strings.Contains(got, "Operation not permitted") {
		t.Fatalf("a connect to another host: %s", got)
	}
}

// TAS-175: a check serves and reaches a unix socket below the temp folder,
// but no socket elsewhere, such as the SSH agent, and no link to one.
func TestProfileAllowsUnixSocketsOnlyBelowTheWrites(t *testing.T) {
	r, _, _, _ := boxedHome(t)
	temp, other := shortTemp(t), shortTemp(t)
	if got := network(t, r, temp, "serve", filepath.Join(temp, "s")); got != "ok" {
		t.Fatalf("a socket in the temp folder: %s", got)
	}
	agent := filepath.Join(other, "agent")
	ln, err := net.Listen("unix", agent)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	link := filepath.Join(temp, "link")
	if err := os.Symlink(agent, link); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{agent, link} {
		if got := network(t, r, temp, "connect", path); !strings.Contains(got, "Operation not permitted") {
			t.Errorf("a connect to %s: %s", path, got)
		}
	}
	if got := network(t, r, temp, "serve", filepath.Join(other, "s")); !strings.Contains(got, "Operation not permitted") {
		t.Errorf("a socket outside the writes: %s", got)
	}
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// TAS-175: the temp folders are the temp folder of the process and the cache
// folder of the user, where clang keeps its module cache. A check writes in
// both.
func TestTempsHoldTheUserCache(t *testing.T) {
	temps := Temps()
	if len(temps) != 2 || temps[0] != os.TempDir() || !strings.HasSuffix(filepath.Clean(temps[1]), "/C") {
		t.Fatalf("temps %q", temps)
	}
	r, _, _, _ := boxedHome(t)
	dir, err := os.MkdirTemp(temps[1], "loam-test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if out, ok := sandboxed(t, r, "", "touch "+shellQuote(filepath.Join(dir, "x"))); ok {
		t.Fatalf("a write to the user cache with no temp folders passed: %s", out)
	}
	if out, ok := sandboxedIn(t, r, temps, "touch "+shellQuote(filepath.Join(dir, "x"))); !ok {
		t.Fatalf("a write to the user cache: %s", out)
	}
}

// TAS-175: a check cannot signal a process outside the sandbox, such as the
// Loam hook, or ask the security services for the keychain. It can signal
// its own processes. The test does not try Launch Services or Apple Events:
// a failed deny would open an app on this Mac.
func TestProfileDeniesOtherProcesses(t *testing.T) {
	r, _, _, _ := boxedHome(t)
	other := exec.Command("/bin/sleep", "60")
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Process.Kill(); _ = other.Wait() })
	pid := strconv.Itoa(other.Process.Pid)
	if out, ok := sandboxed(t, r, "", "kill -0 "+pid); ok {
		t.Errorf("a signal to a process outside the sandbox passed: %s", out)
	}
	if out, ok := sandboxed(t, r, "", "/bin/sleep 60 & kill $!"); !ok {
		t.Errorf("a signal to its own process: %s", out)
	}
	if out, err := exec.Command("/usr/bin/security", "list-keychains").CombinedOutput(); err != nil {
		t.Skipf("security list-keychains fails with no sandbox: %v %s", err, out)
	}
	if out, ok := sandboxed(t, r, "", "/usr/bin/security list-keychains"); ok {
		t.Errorf("the keychain list passed: %s", out)
	}
}
