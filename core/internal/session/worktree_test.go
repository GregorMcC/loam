package session_test

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// wtEnv is a plot with one git repo, one other repo, and a worktree.
type wtEnv struct {
	env
	plot  store.Plot
	repo  string
	other string
	wt    store.Worktree
}

func setupWorktree(t *testing.T) wtEnv {
	t.Helper()
	testutil.GitEnv(t)
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	other := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: repo}, {Path: other}}})
	res, err := worktree.Create(e.store, worktree.CreateOptions{PlotID: p.ID, Repo: repo, Name: "feature"})
	if err != nil {
		t.Fatal(err)
	}
	return wtEnv{env: e, plot: p, repo: repo, other: other, wt: res.Worktree}
}

func (e wtEnv) setupCommand(t *testing.T, cmd string) {
	t.Helper()
	if err := e.store.SetRepoSettings(e.repo, store.S(cmd), nil); err != nil {
		t.Fatal(err)
	}
}

// approvedSetup sets the setup command and approves it, as when you type it
// in the CLI.
func (e wtEnv) approvedSetup(t *testing.T, cmd string) {
	t.Helper()
	e.setupCommand(t, cmd)
	if err := e.store.ApproveSetup(e.repo, cmd); err != nil {
		t.Fatal(err)
	}
}

func (e wtEnv) done(t *testing.T) bool {
	t.Helper()
	w, err := e.store.GetWorktree(e.wt.ID)
	if err != nil {
		t.Fatal(err)
	}
	return w.SetupDone
}

func TestStartInAWorktree(t *testing.T) {
	e := setupWorktree(t)
	out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature", "--session-id", fixedID)
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, e.wt.Path) {
		t.Errorf("cwd %q, want %q", inv.Cwd, e.wt.Path)
	}
	// The plot folder and the other repo attach. The normal checkout does not.
	want := []string{filepath.Join(e.home, "plots", e.plot.ID), e.other}
	if got := argValues(inv.Args, "--add-dir"); !slices.Equal(got, want) {
		t.Errorf("--add-dir %v, want %v", got, want)
	}
	if !strings.Contains(out, session.TrustNote) {
		t.Errorf("no trust note in %q", out)
	}
	recs, _ := e.store.ListSessions(e.plot.ID)
	if len(recs) != 1 || recs[0].StartFolder != e.wt.Path {
		t.Errorf("records %+v", recs)
	}

	// The second session in the same worktree prints no note.
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	out, err = e.run(t, "start", e.plot.ID, "--worktree", e.wt.ID)
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if strings.Contains(out, session.TrustNote) {
		t.Errorf("second start printed the note: %q", out)
	}
}

func TestStartWorktreeErrors(t *testing.T) {
	e := setupWorktree(t)
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "nope"); err == nil || !strings.Contains(out, "nope") {
		t.Errorf("unknown: %v %s", err, out)
	}
	os.RemoveAll(e.wt.Path)
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature"); err == nil || !strings.Contains(out, e.wt.Path) {
		t.Errorf("gone: %v %s", err, out)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
	if recs, _ := e.store.ListSessions(e.plot.ID); len(recs) != 0 {
		t.Errorf("a record was added: %+v", recs)
	}
}

func TestSetupRunsBeforeClaudeAndOnlyUntilItSucceeds(t *testing.T) {
	e := setupWorktree(t)
	// The marker records that claude had not run yet, and that setup ran in the worktree.
	e.approvedSetup(t, `test ! -e "$LOAM_FAKE_CLAUDE_OUT" && echo x >> setup-ran`)
	out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature")
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if b, err := os.ReadFile(filepath.Join(e.wt.Path, "setup-ran")); err != nil || string(b) != "x\n" {
		t.Fatalf("setup did not run first in the worktree: %q %v", b, err)
	}
	if !e.done(t) {
		t.Fatal("success was not recorded")
	}
	testutil.FakeClaudeInvocation(t) // claude ran

	// A second pane does not run it again.
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if b, _ := os.ReadFile(filepath.Join(e.wt.Path, "setup-ran")); string(b) != "x\n" {
		t.Fatalf("setup ran again: %q", b)
	}
}

func TestFailedSetupRunsAgainInTheNextPane(t *testing.T) {
	e := setupWorktree(t)
	e.approvedSetup(t, `echo ran >> attempts; exit 3`)
	out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature")
	if err != nil {
		t.Fatalf("Claude must start after a failed setup: %v: %s", err, out)
	}
	if !strings.Contains(out, "setup command failed") {
		t.Errorf("no warning in %q", out)
	}
	testutil.FakeClaudeInvocation(t)
	if e.done(t) {
		t.Fatal("a failed setup was recorded as done")
	}
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	// The next pane tries again, and now it works. resume does the same as start.
	e.approvedSetup(t, `echo ran >> attempts`)
	if out, err := e.run(t, "resume", latestSession(t, e)); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if b, _ := os.ReadFile(filepath.Join(e.wt.Path, "attempts")); string(b) != "ran\nran\n" {
		t.Fatalf("attempts %q", b)
	}
	if !e.done(t) {
		t.Fatal("success was not recorded")
	}
}

func latestSession(t *testing.T, e wtEnv) string {
	t.Helper()
	recs, err := e.store.ListSessions(e.plot.ID)
	if err != nil || len(recs) == 0 {
		t.Fatalf("%v %v", recs, err)
	}
	return recs[len(recs)-1].SessionID
}

func TestResumeInAWorktree(t *testing.T) {
	e := setupWorktree(t)
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature", "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	out, err := e.run(t, "resume", fixedID)
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if strings.Contains(out, session.TrustNote) {
		t.Errorf("resume printed the trust note: %q", out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, e.wt.Path) {
		t.Errorf("cwd %q", inv.Cwd)
	}
	want := []string{filepath.Join(e.home, "plots", e.plot.ID), e.other}
	if got := argValues(inv.Args, "--add-dir"); !slices.Equal(got, want) {
		t.Errorf("--add-dir %v, want %v", got, want)
	}

	// The worktree is gone: resume fails with an error.
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if _, err := worktree.Remove(e.store, e.plot.ID, e.wt.ID, worktree.RemoveOptions{}); err != nil {
		t.Fatal(err)
	}
	out, err = e.run(t, "resume", fixedID)
	if err == nil || !strings.Contains(out, "worktree") || !strings.Contains(out, e.wt.Path) {
		t.Fatalf("want an error about the worktree, got %v: %s", err, out)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
}

func TestUnapprovedSetupIsSkippedWithoutATerminal(t *testing.T) {
	e := setupWorktree(t)
	// Set through MCP: stored, but not approved.
	e.setupCommand(t, `echo x > setup-ran`)
	out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature")
	if err != nil {
		t.Fatalf("Claude must start: %v: %s", err, out)
	}
	if !strings.Contains(out, "Skipped the setup command because it is new or changed") {
		t.Errorf("no warning in %q", out)
	}
	if _, err := os.Stat(filepath.Join(e.wt.Path, "setup-ran")); err == nil {
		t.Fatal("an unapproved setup command ran")
	}
	if e.done(t) {
		t.Fatal("a skipped setup was recorded as done")
	}
	testutil.FakeClaudeInvocation(t)

	// A command that changes after approval needs approval again.
	e.approvedSetup(t, `echo a > approved`)
	e.setupCommand(t, `echo b > changed`)
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature"); err != nil || !strings.Contains(out, "Skipped the setup command") {
		t.Fatalf("a changed command must be skipped: %v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(e.wt.Path, "changed")); err == nil {
		t.Fatal("a changed setup command ran")
	}
}

func TestSetupFromTheCLIIsApproved(t *testing.T) {
	e := setupWorktree(t)
	if out, err := e.run(t, "repo", "edit", e.plot.ID, e.repo, "--setup", "echo x > setup-ran"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if out, err := e.run(t, "start", e.plot.ID, "--worktree", "feature"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(e.wt.Path, "setup-ran")); err != nil {
		t.Fatal("a setup command that you typed did not run")
	}
}

func TestBeforeExecAsksOnATerminal(t *testing.T) {
	for _, c := range []struct {
		answer string
		runs   bool
	}{{"y\n", true}, {"yes\n", true}, {"n\n", false}, {"\n", false}, {"", false}} {
		e := setupWorktree(t)
		e.setupCommand(t, `echo x > setup-ran`)
		set, err := e.store.RepoSettings(e.repo)
		if err != nil {
			t.Fatal(err)
		}
		w := e.wt
		plan := &session.Plan{Worktree: &w, Setup: set.Setup, SetupApproved: set.Setup == set.SetupApproved}
		var out, errOut strings.Builder
		if err := session.BeforeExec(plan, strings.NewReader(c.answer), true, &out, &errOut); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), "Run it? [y/N]") {
			t.Errorf("%q: no question in %q", c.answer, out.String())
		}
		_, statErr := os.Stat(filepath.Join(e.wt.Path, "setup-ran"))
		if ran := statErr == nil; ran != c.runs {
			t.Errorf("%q: ran %v, want %v", c.answer, ran, c.runs)
		}
		after, _ := e.store.RepoSettings(e.repo)
		if approved := after.SetupApproved == set.Setup; approved != c.runs {
			t.Errorf("%q: approved %v, want %v", c.answer, approved, c.runs)
		}
	}
}
