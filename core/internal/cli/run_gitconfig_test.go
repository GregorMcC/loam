package cli

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// includeInGlobalConfig adds an include of target to the global git config of
// the test.
func includeInGlobalConfig(t *testing.T, target string) {
	t.Helper()
	f, err := os.OpenFile(os.Getenv("GIT_CONFIG_GLOBAL"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteString("[include]\n\tpath = " + target + "\n"); err != nil {
		t.Fatal(err)
	}
}

// TAS-191: a run does not start with a git config include in a write path. It
// is stopped, and the note says why. No session starts.
func TestRunStartStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, p := runCLI(t)
	target := filepath.Join(p.Repos[0].Path, ".git", "team.gitconfig")
	includeInGlobalConfig(t, target)
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "A run", "--json"); err == nil {
		t.Fatal("run start gives no error")
	}
	runs, err := s.ListRuns(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 || runs[0].State != store.RunStopped || !strings.Contains(runs[0].Note, target) || !strings.Contains(runs[0].Note, "Remove the include") {
		t.Fatalf("runs %+v, want one stopped run with a note on %s", runs, target)
	}
	if got := bgStarts(t); len(got) != 0 {
		t.Fatalf("session starts %q, want none", got)
	}
}

// TAS-191: the same check runs before a resume, and a failure there stops the
// run. The session gets no prompt.
func TestRunSendBackStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, r, _ := readyRun(t)
	before := len(testutil.FakeClaudeCalls(t))
	target := filepath.Join(r.Folder, "team.gitconfig")
	includeInGlobalConfig(t, target)
	if _, code, out := sendBack(t, r.ID, "--note", "Add a test."); code == 0 {
		t.Fatalf("send-back exits 0: %s", out)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || !strings.Contains(got.Note, target) {
		t.Fatalf("run %+v, want stopped with a note on %s", got, target)
	}
	for _, c := range testutil.FakeClaudeCalls(t)[before:] {
		if slices.Contains(c, "--resume") {
			t.Fatalf("the session got a prompt: %q", c)
		}
	}
}

// TAS-191: the gate builds the rules again, and runs no check when the config
// changed so that the run can write it.
func TestRunGateStopsARunWithAGitConfigIncludeInAWritePath(t *testing.T) {
	s, r := gateRun(t, "3")
	target := filepath.Join(r.Folder, "team.gitconfig")
	includeInGlobalConfig(t, target)
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunStopped || got.Tries != 0 || !strings.Contains(got.Note, target) {
		t.Fatalf("after the gate: %+v, want stopped with a note on %s", got, target)
	}
}
