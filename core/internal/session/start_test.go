package session_test

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

type env struct {
	home  string
	bin   string
	store *store.Store
}

func setup(t *testing.T) env {
	t.Helper()
	home := testutil.Home(t)
	testutil.FakeClaude(t)
	// A parent Claude session leaves these in the environment. A pane must not inherit them.
	t.Setenv("CLAUDE_PID", "999")
	t.Setenv("LOAM_CLAUDE_EXTRA_ARGS", "[]")
	t.Setenv("CLAUDE_CODE_SESSION_ID", "old")
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return env{home: home, bin: testutil.BuildLoam(t), store: s}
}

func (e env) plot(t *testing.T, in store.PlotInput) store.Plot {
	t.Helper()
	res, err := e.store.CreatePlot(in, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	return res.Plot
}

func (e env) run(t *testing.T, args ...string) (string, error) {
	t.Helper()
	out, err := exec.Command(e.bin, args...).CombinedOutput()
	return string(out), err
}

func realpath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func argValues(args []string, flag string) []string {
	var out []string
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			out = append(out, args[i+1])
		}
	}
	return out
}

const fixedID = "11111111-2222-4333-8444-555555555555"

func TestStartPlotWithRepos(t *testing.T) {
	e := setup(t)
	main, other, linkDir := t.TempDir(), t.TempDir(), t.TempDir()
	p := e.plot(t, store.PlotInput{
		Name: "Alpha", What: "w",
		Repos: []store.RepoInput{{Path: main}, {Path: other}},
		Links: []store.LinkInput{
			{Label: "docs", Target: linkDir},
			{Label: "web", Target: "https://example.com"},
		},
	})
	if out, err := e.run(t, "start", p.ID, "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, main) {
		t.Errorf("cwd %q, want main repo %q", inv.Cwd, main)
	}
	if inv.Env["LOAM_PLOT"] != p.ID {
		t.Errorf("LOAM_PLOT = %q", inv.Env["LOAM_PLOT"])
	}
	if inv.Env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] != "1" {
		t.Error("the CLAUDE.md env var is not set")
	}
	if _, ok := inv.Env["CLAUDE_PID"]; ok {
		t.Error("CLAUDE_PID leaked into the session")
	}
	if _, ok := inv.Env["CLAUDE_CODE_SESSION_ID"]; ok {
		t.Error("CLAUDE_CODE_SESSION_ID leaked into the session")
	}
	if _, ok := inv.Env["LOAM_CLAUDE_EXTRA_ARGS"]; ok {
		t.Error("LOAM_CLAUDE_EXTRA_ARGS leaked into the session")
	}
	if got := argValues(inv.Args, "--session-id"); !slices.Equal(got, []string{fixedID}) {
		t.Errorf("--session-id %v", got)
	}
	dirs := argValues(inv.Args, "--add-dir")
	want := []string{filepath.Join(e.home, "plots", p.ID), other, linkDir}
	if !slices.Equal(dirs, want) {
		t.Errorf("--add-dir %v, want %v", dirs, want)
	}
	if _, err := os.Stat(seed.Path(e.store, p.ID)); err != nil {
		t.Errorf("no seed: %v", err)
	}
	rec, err := e.store.GetSession(fixedID)
	if err != nil || rec.PlotID != p.ID || realpath(t, rec.StartFolder) != realpath(t, main) {
		t.Errorf("session record %+v, %v", rec, err)
	}
}

func TestStartSettingsFile(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if out, err := e.run(t, "start", p.ID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	files := argValues(inv.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("--settings %v", files)
	}
	b, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var s struct {
		Permissions struct{ Allow, Ask []string }
		Hooks       map[string][]struct {
			Matcher string
			Hooks   []struct{ Type, Command string }
		}
	}
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	wantAllow := []string{"mcp__loam__list_plots", "mcp__loam__get_plot", "mcp__loam__get_changes", "mcp__loam__add_link", "mcp__loam__update_link", "mcp__loam__list_worktrees"}
	if !slices.Equal(s.Permissions.Allow, wantAllow) {
		t.Errorf("allow %v", s.Permissions.Allow)
	}
	// No ask rules (ticket 84): only the auto mode classifier guards the write tools.
	if s.Permissions.Ask != nil {
		t.Errorf("ask %v", s.Permissions.Ask)
	}
	ss := s.Hooks["SessionStart"]
	if len(ss) != 1 || len(ss[0].Hooks) != 1 || ss[0].Hooks[0].Type != "command" {
		t.Fatalf("hooks %+v", s.Hooks)
	}
	cmd := ss[0].Hooks[0].Command
	if !strings.HasSuffix(cmd, " hook") || !strings.HasPrefix(cmd, "'/") {
		t.Errorf("hook command %q must hold an absolute, quoted path", cmd)
	}
}

func TestStartNoReposStartsInPlotFolder(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	if out, err := e.run(t, "start", "Alpha"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, filepath.Join(e.home, "plots", p.ID)) {
		t.Errorf("cwd %q", inv.Cwd)
	}
	if dirs := argValues(inv.Args, "--add-dir"); len(dirs) != 1 {
		t.Errorf("--add-dir %v", dirs)
	}
	id := argValues(inv.Args, "--session-id")
	if len(id) != 1 || !regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`).MatchString(id[0]) {
		t.Errorf("generated session ID %v", id)
	}
}

func TestStartWithRepoFlag(t *testing.T) {
	e := setup(t)
	main, other := t.TempDir(), t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}, {Path: other}}})
	if out, err := e.run(t, "start", p.ID, "--repo", other); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realpath(t, inv.Cwd) != realpath(t, other) {
		t.Errorf("cwd %q", inv.Cwd)
	}
	dirs := argValues(inv.Args, "--add-dir")
	if !slices.Contains(dirs, main) || slices.Contains(dirs, other) {
		t.Errorf("--add-dir %v: want the main repo, not the start repo", dirs)
	}
}

func TestStartWithRepoID(t *testing.T) {
	e := setup(t)
	main, other := t.TempDir(), t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}, {Path: other}}})
	var id string
	for _, r := range p.Repos {
		if r.Path == other {
			id = r.ID
		}
	}
	if out, err := e.run(t, "start", p.ID, "--repo", id); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if inv := testutil.FakeClaudeInvocation(t); realpath(t, inv.Cwd) != realpath(t, other) {
		t.Errorf("cwd %q", inv.Cwd)
	}
}

func TestStartRepoFlagMustBeInPlot(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: t.TempDir()}}})
	out, err := e.run(t, "start", p.ID, "--repo", t.TempDir())
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 || !strings.Contains(out, "no repo") {
		t.Fatalf("want exit code 1 and \"no repo\", got %v: %s", err, out)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
}

func TestStartMissingMainRepoFails(t *testing.T) {
	e := setup(t)
	gone := filepath.Join(t.TempDir(), "gone")
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: gone}}})
	out, err := e.run(t, "start", p.ID)
	if err == nil || !strings.Contains(out, gone) {
		t.Fatalf("want an error that names the path, got %v: %s", err, out)
	}
	if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
		t.Error("claude started")
	}
	if recs, _ := e.store.ListSessions(p.ID); len(recs) != 0 {
		t.Errorf("session records %v", recs)
	}
}

func TestStartUnknownPlotFails(t *testing.T) {
	e := setup(t)
	if _, err := e.run(t, "start", "nothing"); err == nil {
		t.Fatal("want an error")
	}
}

func TestStartSessionIDChecks(t *testing.T) {
	e := setup(t)
	a := e.plot(t, store.PlotInput{Name: "A"})
	b := e.plot(t, store.PlotInput{Name: "B"})
	if out, err := e.run(t, "start", a.ID, "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if _, err := e.run(t, "start", b.ID, "--session-id", fixedID); err == nil {
		t.Fatal("want an error for an ID that belongs to another plot")
	}
	if _, err := e.run(t, "start", a.ID, "--session-id", "not-a-uuid"); err == nil {
		t.Fatal("want an error for a bad session ID")
	}
}

// Ticket 93: --plot-folder starts in the plot folder of a plot with repos. Every repo and local
// link is an added folder.
func TestStartInThePlotFolder(t *testing.T) {
	e := setup(t)
	main, other, linkDir := t.TempDir(), t.TempDir(), t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}, {Path: other}},
		Links: []store.LinkInput{{Label: "docs", Target: linkDir}}})
	if out, err := e.run(t, "start", p.ID, "--plot-folder"); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	plotDir := filepath.Join(e.home, "plots", p.ID)
	if realpath(t, inv.Cwd) != realpath(t, plotDir) {
		t.Errorf("cwd %q, want the plot folder", inv.Cwd)
	}
	if dirs, want := argValues(inv.Args, "--add-dir"), []string{plotDir, main, other, linkDir}; !slices.Equal(dirs, want) {
		t.Errorf("--add-dir %v, want %v", dirs, want)
	}
}

func TestStartPlotFolderRefusesARepoOrAWorktree(t *testing.T) {
	e := setup(t)
	main := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}}})
	for _, args := range [][]string{{"--repo", main}, {"--worktree", "x"}} {
		out, err := e.run(t, append([]string{"start", p.ID, "--plot-folder"}, args...)...)
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 2 || !strings.Contains(out, "--plot-folder") {
			t.Fatalf("%v: want exit code 2 that names --plot-folder, got %v: %s", args, err, out)
		}
	}
}
