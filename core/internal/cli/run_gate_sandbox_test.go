package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-175: the gate runs each check in sandbox-exec with a profile of the
// rules of the run.
func TestRunGateRunsTheChecksInTheSandbox(t *testing.T) {
	s, r := gateRun(t, "3")
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("passing gate: code %d, reason:\n%s", code, reason)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("after the gate: %+v", got)
	}
	copied := os.Getenv("LOAM_FAKE_SANDBOX_PROFILE")
	b, err := os.ReadFile(copied)
	if err != nil {
		t.Fatal(err)
	}
	home, _ := os.UserHomeDir()
	folder := realPath(t, r.Folder)
	for _, want := range []string{
		"(deny file-read*\n  (subpath \"" + realPath(t, home) + "\"))",
		"(deny file-write*)\n(allow file-write*\n  (subpath \"" + folder + "\")",
		"/hooks\")",
	} {
		if !strings.Contains(string(b), want) {
			t.Errorf("the profile has no %q:\n%s", want, b)
		}
	}
}

// The checks get the folder of the gate as TMPDIR, and the xcrun shims keep
// their cache there, not in the cache of the user, which the profile denies.
// Go takes its modules from the module cache. The gate removes the folder.
func TestRunGateGivesTheChecksAFolderOfTheGate(t *testing.T) {
	s, _ := runCLI(t)
	record := filepath.Join(t.TempDir(), "xcrun_db")
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--max-tries", "3",
		"--check", `Cache=printf '%s\n%s\n%s' "$TMPDIR" "$xcrun_db" "$GOPROXY" > `+record, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var started runStartOut
	if err := json.Unmarshal([]byte(out), &started); err != nil {
		t.Fatal(err)
	}
	if code, reason := stopHook(t, started.Run, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	b, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	env := strings.Split(string(b), "\n")
	if len(env) != 3 {
		t.Fatalf("env = %q", env)
	}
	tmp, cache, proxy := env[0], env[1], env[2]
	// The gate uses /tmp, or the temp folder when a sandbox denies /tmp.
	if base := filepath.Base(tmp); !strings.HasPrefix(base, "loam-gate-") ||
		(filepath.Dir(tmp) != "/tmp" && filepath.Dir(tmp) != filepath.Clean(os.TempDir())) ||
		cache != filepath.Join(tmp, "xcrun-cache") {
		t.Fatalf("TMPDIR = %q, xcrun_db = %q, want the folder of the gate and a file in it", tmp, cache)
	}
	// The gate has no network, so Go takes the modules from its cache.
	home, _ := os.UserHomeDir()
	if want := "file://" + filepath.Join(sandbox.GoModCache(home, os.Getenv), "cache", "download"); proxy != want {
		t.Errorf("GOPROXY = %q, want %q", proxy, want)
	}
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Errorf("the folder %s is still there: %v", tmp, err)
	}
	if got, _ := s.GetRun(started.Run.ID); got.State != store.RunReady {
		t.Fatalf("after the gate: %+v", got)
	}
}

// TAS-175: with no sandbox-exec, the checks fail closed. None runs, no try
// counts, and the run is Stopped with the reason in its note.
func TestRunGateWithNoSandboxRunsNoCheck(t *testing.T) {
	s, r := gateRun(t, "3")
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	t.Setenv("LOAM_SANDBOX_EXEC", "/no/sandbox-exec")
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	const note = "Loam did not run the checks, because it could not sandbox them: /no/sandbox-exec is missing"
	if got.State != store.RunStopped || got.Tries != 0 || !strings.HasPrefix(got.Note, note) {
		t.Fatalf("after the gate: %+v", got)
	}
	events, _ := s.RunEvents(r.ID)
	for _, e := range events {
		if e.Kind == "check" && strings.Contains(e.Detail, "passed") {
			t.Errorf("a check ran: %+v", e)
		}
	}
}

// TAS-175: a run whose rules fail, as when git cannot name its git folder,
// runs no check.
func TestRunGateWithNoRulesRunsNoCheck(t *testing.T) {
	s, r := gateRun(t, "3")
	if err := os.Remove(filepath.Join(r.Folder, ".git")); err != nil {
		t.Fatal(err)
	}
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunStopped || !strings.Contains(got.Note, "could not sandbox them: find the git folder of ") {
		t.Fatalf("after the gate: %+v", got)
	}
}

// TAS-175: with the real sandbox-exec, a check works in the run folder, and a
// check that writes outside the rules fails.
func TestRunGateWithTheRealSandbox(t *testing.T) {
	testutil.NeedSandbox(t)
	s, _ := runCLI(t)
	t.Setenv("LOAM_SANDBOX_EXEC", "")
	// The temp folders of the test are temp folders of the gate, which the
	// checks can write. /private/var/tmp is not.
	dir, err := os.MkdirTemp("/private/var/tmp", "loam-gate")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	outside := filepath.Join(dir, "escaped")
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--max-tries", "3",
		"--check", "Hello=grep -qx 'hi there' hello.txt && touch built",
		"--check", "Escape=touch "+outside, "--json")
	if err != nil {
		t.Fatal(err)
	}
	var started runStartOut
	if err := json.Unmarshal([]byte(out), &started); err != nil {
		t.Fatal(err)
	}
	r := started.Run
	if err := os.WriteFile(filepath.Join(r.Folder, ".gitignore"), []byte("built\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	testutil.Git(t, r.Folder, "add", ".gitignore")
	testutil.Git(t, r.Folder, "commit", "-qm", "Ignore built")
	code, reason := stopHook(t, r, "Stop")
	if code != 2 || !strings.Contains(reason, "1 of 3 checks failed") || !strings.Contains(reason, "## Escape") ||
		!strings.Contains(reason, "Operation not permitted") {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	if _, err := os.Stat(filepath.Join(r.Folder, "built")); err != nil {
		t.Errorf("the check did not write the run folder: %v", err)
	}
	if _, err := os.Stat(outside); err == nil {
		t.Error("the check wrote outside the rules")
	}
	if got, _ := s.GetRun(r.ID); got.Tries != 1 {
		t.Fatalf("after the gate: %+v", got)
	}
}

// TAS-175: a sandbox that cannot start, as in a process that is already in a
// sandbox, fails the gate once. No check runs, and no try counts.
func TestRunGateWithASandboxThatCannotStartRunsNoCheck(t *testing.T) {
	s, r := gateRun(t, "3")
	bin := filepath.Join(t.TempDir(), "sandbox-exec")
	script := "#!/bin/sh\necho 'sandbox-exec: sandbox_apply: Operation not permitted' >&2\nexit 71\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_SANDBOX_EXEC", bin)
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunStopped || got.Tries != 0 || !strings.Contains(got.Note, "sandbox-exec cannot start the sandbox") ||
		!strings.Contains(got.Note, "sandbox_apply: Operation not permitted") {
		t.Fatalf("after the gate: %+v", got)
	}
}
