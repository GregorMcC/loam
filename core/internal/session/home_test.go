package session_test

import (
	"errors"
	"os/exec"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// homeDir moves HOME to a temp folder, so a Home session has a known start folder.
func homeDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	return dir
}

// Ticket 99: a Home session starts in the home folder with no seed, no added folders, and no
// LOAM_PLOT. It keeps the settings file, so the pane hooks and the allow rules work.
func TestStartHome(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	// A parent seeded session leaves its plot in the environment.
	t.Setenv("LOAM_PLOT", "parent")
	e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: t.TempDir()}}})
	if out, err := e.run(t, "start", "--home", "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, home) {
		t.Errorf("cwd %q, want the home folder %q", inv.Cwd, home)
	}
	for _, k := range []string{"LOAM_PLOT", "CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "LOAM_CLAUDE_EXTRA_ARGS"} {
		if v, ok := inv.Env[k]; ok {
			t.Errorf("%s = %q in a Home session", k, v)
		}
	}
	if got := argValues(inv.Args, "--session-id"); !slices.Equal(got, []string{fixedID}) {
		t.Errorf("--session-id %v", got)
	}
	if got := argValues(inv.Args, "--add-dir"); len(got) != 0 {
		t.Errorf("--add-dir %v in a Home session", got)
	}
	if got := argValues(inv.Args, "--settings"); len(got) != 1 || !strings.HasSuffix(got[0], fixedID+".json") {
		t.Errorf("--settings %v", got)
	}
	if ok, err := e.store.IsSeeded(fixedID); err != nil || ok {
		t.Errorf("a Home session has a session record: %v, %v", ok, err)
	}
}

func TestStartHomePicksASessionID(t *testing.T) {
	e := setup(t)
	homeDir(t)
	if out, err := e.run(t, "start", "--home"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	id := argValues(testutil.FakeClaudeInvocation(t).Args, "--session-id")
	if len(id) != 1 || !uuidV4.MatchString(id[0]) {
		t.Errorf("generated session ID %v", id)
	}
}

// Claude Code finds a session by its start folder. A Home session always starts in the home
// folder, so a resume there finds it with no session record.
func TestStartHomeResume(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	if out, err := e.run(t, "start", "--home", "--resume", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, home) {
		t.Errorf("cwd %q, want the home folder %q", inv.Cwd, home)
	}
	if got := argValues(inv.Args, "--resume"); !slices.Equal(got, []string{fixedID}) {
		t.Errorf("--resume %v", got)
	}
	if got := argValues(inv.Args, "--session-id"); len(got) != 0 {
		t.Errorf("--session-id %v on resume", got)
	}
	if got := argValues(inv.Args, "--settings"); len(got) != 1 || !strings.HasSuffix(got[0], fixedID+".json") {
		t.Errorf("--settings %v", got)
	}
	if _, ok := inv.Env["LOAM_PLOT"]; ok {
		t.Error("LOAM_PLOT in a resumed Home session")
	}
}

func TestStartHomeUsageErrors(t *testing.T) {
	e := setup(t)
	homeDir(t)
	e.plot(t, store.PlotInput{Name: "Alpha"})
	for _, args := range [][]string{
		{"--home", "Alpha"},
		{"--home", "--repo", "x"},
		{"--home", "--worktree", "x"},
		{"--home", "--plot-folder"},
		{"--home", "--session-id", fixedID, "--resume", fixedID},
		{"--home", "--resume", "not-a-uuid"},
		{"--home", "--session-id", "not-a-uuid"},
		{"Alpha", "--resume", fixedID},
		{},
	} {
		out, err := e.run(t, append([]string{"start"}, args...)...)
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 2 {
			t.Errorf("start %v: want exit code 2, got %v: %s", args, err, out)
		}
	}
}

// A Home session has no LOAM_PLOT and no session record. Its hooks still reach the pane, and a
// clear or a resume adds no record.
func TestHookFromAHomeSession(t *testing.T) {
	e := setup(t)
	path, lines := listen(t)
	env := map[string]string{"LOAM_PANE_SOCKET": path, "CLAUDE_PID": "4245"}
	for _, source := range []string{"startup", "clear", "resume"} {
		runHook(t, `{"session_id":"home-`+source+`","cwd":"/home","hook_event_name":"SessionStart","source":"`+source+`"}`, env)
		if line := nextLine(t, lines); !strings.Contains(line, `"source":"`+source+`"`) {
			t.Errorf("%s: pane line %s", source, line)
		}
		if ok, _ := e.store.IsSeeded("home-" + source); ok {
			t.Errorf("%s: a Home session got a session record", source)
		}
	}
	if log := hookLog(t, e.home); log != "" {
		t.Errorf("hook log %q", log)
	}
}
