package session_test

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// runIn runs loam in a folder.
func (e env) runIn(t *testing.T, dir string, args ...string) (string, error) {
	t.Helper()
	cmd := exec.Command(e.bin, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// conversation makes the file where Claude Code keeps the conversation of the
// session, in a temp CLAUDE_CONFIG_DIR.
func conversation(t *testing.T, sessionID string) {
	t.Helper()
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	dir := filepath.Join(cfg, "projects", "-Users-me")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, sessionID+".jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exitCode(err error) int {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	return 0
}

// Ticket 100: a Home session has no record. resume --plot records it in the
// plot with the home folder as its start folder, from any folder, then resumes
// it as a seeded session of that plot.
func TestResumeIntoAPlotRecordsTheSession(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	repo := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}}})
	conversation(t, fixedID)
	if out, err := e.runIn(t, t.TempDir(), "resume", fixedID, "--plot", "Alpha"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, home) {
		t.Errorf("cwd %q, want %q", inv.Cwd, home)
	}
	if got := argValues(inv.Args, "--resume"); !slices.Equal(got, []string{fixedID}) {
		t.Errorf("--resume %v", got)
	}
	want := []string{filepath.Join(e.home, "plots", p.ID), repo}
	if got := argValues(inv.Args, "--add-dir"); !slices.Equal(got, want) {
		t.Errorf("--add-dir %v, want %v", got, want)
	}
	if inv.Env["LOAM_PLOT"] != p.ID {
		t.Errorf("LOAM_PLOT %q, want %q", inv.Env["LOAM_PLOT"], p.ID)
	}
	rec, err := e.store.GetSession(fixedID)
	if err != nil {
		t.Fatal(err)
	}
	if rec.PlotID != p.ID || realpath(t, rec.StartFolder) != realpath(t, home) {
		t.Errorf("record %+v, want plot %s in %s", rec, p.ID, home)
	}

	// From now on the session is a recorded session of the plot.
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if out, err := e.run(t, "resume", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if inv := testutil.FakeClaudeInvocation(t); realpath(t, inv.Cwd) != realpath(t, home) {
		t.Errorf("a plain resume runs in %q, want %q", inv.Cwd, home)
	}
}

// A session that never had a prompt has no conversation, so claude --resume
// would fail. It starts again with the same ID, in the plot.
func TestResumeIntoAPlotWithNoConversationStartsTheSession(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if out, err := e.runIn(t, home, "resume", fixedID, "--plot", "Alpha"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if got := argValues(inv.Args, "--session-id"); !slices.Equal(got, []string{fixedID}) || slices.Contains(inv.Args, "--resume") {
		t.Errorf("args %v, want --session-id %s and no --resume", inv.Args, fixedID)
	}
	if inv.Env["LOAM_PLOT"] != p.ID {
		t.Errorf("LOAM_PLOT %q, want %q", inv.Env["LOAM_PLOT"], p.ID)
	}
	if rec, err := e.store.GetSession(fixedID); err != nil || rec.PlotID != p.ID {
		t.Errorf("record %+v, %v", rec, err)
	}
}

// A launch that fails adds no record, so the session is still a Home session.
func TestAFailedResumeIntoAPlotAddsNoRecord(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	e.plot(t, store.PlotInput{Name: "Alpha"})
	t.Setenv("LOAM_CLAUDE_EXTRA_ARGS", "not json")
	if out, err := e.runIn(t, home, "resume", fixedID, "--plot", "Alpha"); err == nil {
		t.Fatalf("want an error, got: %s", out)
	}
	if _, err := e.store.GetSession(fixedID); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("a record was added: %v", err)
	}
}

// A second resume --plot into the same plot resumes again, so the app can
// start a moved pane again after a failure.
func TestResumeIntoTheSamePlotAgain(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	for range 2 {
		if out, err := e.runIn(t, home, "resume", fixedID, "--plot", p.ID); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	if recs, _ := e.store.ListSessions(p.ID); len(recs) != 1 {
		t.Errorf("records %v, want 1", recs)
	}
}

// --plot never moves a session from one plot to another.
func TestResumeIntoAnotherPlotIsRefused(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	a := e.plot(t, store.PlotInput{Name: "Alpha"})
	e.plot(t, store.PlotInput{Name: "Beta"})
	if err := e.store.AddSession(store.SessionRecord{SessionID: fixedID, PlotID: a.ID, StartFolder: home}); err != nil {
		t.Fatal(err)
	}
	out, err := e.runIn(t, home, "resume", fixedID, "--plot", "Beta")
	if exitCode(err) != 2 || !strings.Contains(out, "Alpha") {
		t.Fatalf("want exit code 2 that names Alpha, got %v: %s", err, out)
	}
	if rec, _ := e.store.GetSession(fixedID); rec.PlotID != a.ID {
		t.Errorf("the record moved to %s", rec.PlotID)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
}

// A plot that does not exist, an archived plot, and a session ID that is not
// a UUID add no record and start nothing.
func TestResumeIntoAPlotRefusesBadInput(t *testing.T) {
	e := setup(t)
	home := homeDir(t)
	e.plot(t, store.PlotInput{Name: "Alpha"})
	old := e.plot(t, store.PlotInput{Name: "Old"})
	if err := e.store.SetArchived(old.ID, true); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"resume", fixedID, "--plot", "Nowhere"},
		{"resume", fixedID, "--plot", old.ID},
		{"resume", "not-a-uuid", "--plot", "Alpha"},
	} {
		if out, err := e.runIn(t, home, args...); err == nil {
			t.Errorf("%v: want an error, got: %s", args, out)
		}
	}
	if _, err := e.store.GetSession(fixedID); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("a record was added: %v", err)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
}
