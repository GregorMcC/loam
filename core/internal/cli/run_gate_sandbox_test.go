package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// gateProfiles returns the profile files that the gate left in the Loam home
// folder.
func gateProfiles(t *testing.T, s *store.Store) []string {
	t.Helper()
	m, err := filepath.Glob(filepath.Join(s.Home(), "gate-*.sb"))
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// TAS-175: the gate runs each check in sandbox-exec with a profile of the
// rules of the run, in a file that only the user can read. It removes the
// file after the gate.
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
	if mode, _ := os.ReadFile(copied + ".mode"); strings.TrimSpace(string(mode)) != "600" {
		t.Errorf("the profile file has mode %s", mode)
	}
	if left := gateProfiles(t, s); len(left) != 0 {
		t.Errorf("the gate left %q", left)
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

// TAS-175: the gate keeps its profile out of the folders that a check can
// write. With the Loam home folder in the temp folder, no check runs.
func TestRunGateRefusesAProfileThatAChecksCanWrite(t *testing.T) {
	s, r := gateRun(t, "3")
	t.Setenv("TMPDIR", filepath.Dir(s.Home()))
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunStopped || !strings.Contains(got.Note, "the checks could write the Loam home folder") {
		t.Fatalf("after the gate: %+v", got)
	}
	if left := gateProfiles(t, s); len(left) != 0 {
		t.Errorf("the gate left %q", left)
	}
}

// TAS-175: with the real sandbox-exec, a check works in the run folder, and a
// check that writes outside the rules fails.
func TestRunGateWithTheRealSandbox(t *testing.T) {
	testutil.NeedSandbox(t)
	s, _ := runCLI(t)
	t.Setenv("LOAM_SANDBOX_EXEC", "")
	outside := filepath.Join(t.TempDir(), "escaped")
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
	if left := gateProfiles(t, s); len(left) != 0 {
		t.Errorf("the gate left %q", left)
	}
}

// TAS-175: the gate removes the profile files that a killed gate left, and
// keeps the file of a gate that may still run.
func TestRunGateRemovesOldProfiles(t *testing.T) {
	s, r := gateRun(t, "3")
	old, fresh := filepath.Join(s.Home(), "gate-old.sb"), filepath.Join(s.Home(), "gate-fresh.sb")
	for _, f := range []string{old, fresh} {
		if err := os.WriteFile(f, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	long := time.Now().Add(-2 * session.RunHookTimeout * time.Second)
	if err := os.Chtimes(old, long, long); err != nil {
		t.Fatal(err)
	}
	stopHook(t, r, "Stop")
	if left := gateProfiles(t, s); len(left) != 1 || left[0] != fresh {
		t.Fatalf("left %q, want only %s", left, fresh)
	}
}
