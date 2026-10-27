package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// runCLI is a plot with one repo, a fake claude, and a Claude Code config
// that trusts the worktrees folder of the Loam home.
func runCLI(t *testing.T) (*store.Store, store.Plot) {
	t.Helper()
	s, p, _ := wtCLI(t)
	testutil.FakeClaude(t)
	trustFolder(t, filepath.Join(s.Home(), "worktrees"))
	return s, p
}

// trustFolder points CLAUDE_CONFIG_DIR at a config that trusts dir, or that
// trusts nothing when dir is empty.
func trustFolder(t *testing.T, dir string) {
	t.Helper()
	cfg := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", cfg)
	projects := map[string]any{}
	if dir != "" {
		projects[dir] = map[string]bool{"hasTrustDialogAccepted": true}
	}
	b, _ := json.Marshal(map[string]any{"projects": projects})
	if err := os.WriteFile(filepath.Join(cfg, ".claude.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
}

type runStartOut struct {
	Run      store.Run      `json:"run"`
	Worktree store.Worktree `json:"worktree"`
}

func TestRunStartLaunchesABackgroundSessionInANewWorktree(t *testing.T) {
	s, p := runCLI(t)
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Drag a link to reorder",
		"--goal", "A link in the brief moves by drag.", "--check", "Go tests=go test ./...", "--check", "Vet=go vet ./...", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got runStartOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	r, w := got.Run, got.Worktree
	if r.State != store.RunRunning || r.Folder != w.Path || r.WorktreeID != w.ID || len(r.DoneWhen) != 2 || r.MaxTries != store.DefaultMaxTries {
		t.Fatalf("run %+v", r)
	}
	// The worktree name comes from the title.
	if w.Name != "drag-a-link-to-reorder" || w.Goal != "Drag a link to reorder" {
		t.Fatalf("worktree %+v", w)
	}

	inv := testutil.FakeClaudeInvocation(t)
	if realPath(t, inv.Cwd) != realPath(t, w.Path) {
		t.Fatalf("cwd %s, want %s", inv.Cwd, w.Path)
	}
	args := inv.Args
	for _, want := range [][]string{{"--bg"}, {"--name", "loam-run-" + r.ID}, {"--permission-mode", "auto"}, {"--add-dir", s.PlotDir(p.ID)}} {
		if !containsRun(args, want) {
			t.Errorf("args %q miss %q", args, want)
		}
	}
	if slices.Contains(args, "--session-id") {
		t.Errorf("--bg ignores --session-id, so Loam must not pass it: %q", args)
	}
	prompt := args[len(args)-1]
	for _, want := range []string{"Drag a link to reorder", "A link in the brief moves by drag.", "go test ./...", "go vet ./...", "3 tries"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
	if inv.Env["LOAM_PLOT"] != p.ID {
		t.Errorf("LOAM_PLOT %q", inv.Env["LOAM_PLOT"])
	}

	// The settings file sends the run's hooks to loam run hook <id>, and
	// sets the plot in the session's env, which the supervisor may not pass.
	var settings struct {
		Env   map[string]string `json:"env"`
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
				Timeout int    `json:"timeout"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	b, err := os.ReadFile(argAfter(args, "--settings"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &settings); err != nil {
		t.Fatal(err)
	}
	if settings.Env["LOAM_PLOT"] != p.ID || settings.Env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] != "1" {
		t.Errorf("settings env %v", settings.Env)
	}
	for _, ev := range []string{"SessionStart", "Stop", "StopFailure"} {
		h := settings.Hooks[ev]
		if len(h) != 1 || len(h[0].Hooks) != 1 || !strings.HasSuffix(h[0].Hooks[0].Command, " run hook "+r.ID) {
			t.Errorf("%s hook %+v", ev, h)
		}
	}
	if stop := settings.Hooks["Stop"][0].Hooks[0]; stop.Timeout < 600 {
		t.Errorf("the Stop hook runs the checks and needs a long timeout: %d", stop.Timeout)
	}

	// The run is in the store, and list shows it.
	out, _, err = lrRun(t, "", "run", "list", "alpha", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var listed []store.Run
	if err := json.Unmarshal([]byte(out), &listed); err != nil || len(listed) != 1 || listed[0].ID != r.ID {
		t.Fatalf("list %s %v", out, err)
	}
}

func TestRunStartRefusesAFolderThatClaudeCodeDoesNotTrust(t *testing.T) {
	s, _ := runCLI(t)
	trustFolder(t, "")
	_, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Fix the thing")
	if err == nil || !strings.Contains(err.Error(), filepath.Join(s.Home(), "worktrees")) {
		t.Fatalf("err %v", err)
	}
	if runs, _ := s.ListRuns(""); len(runs) != 0 {
		t.Fatalf("a refused start recorded a run: %+v", runs)
	}
}

func TestRunStartRefusesASetupCommandThatYouHaveNotApproved(t *testing.T) {
	s, p := runCLI(t)
	repo := p.Repos[0].Path
	if err := s.SetRepoSettings(repo, store.S("touch set-up"), nil); err != nil {
		t.Fatal(err)
	}
	_, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Fix the thing")
	if !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), "--approve-setup") {
		t.Fatalf("err %v", err)
	}
	// --approve-setup approves the command, runs it, and starts the run.
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Fix the thing", "--approve-setup", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got runStartOut
	json.Unmarshal([]byte(out), &got)
	if _, err := os.Stat(filepath.Join(got.Worktree.Path, "set-up")); err != nil {
		t.Fatalf("setup did not run: %v", err)
	}
	if set, _ := s.RepoSettings(repo); set.SetupApproved != "touch set-up" {
		t.Fatalf("not approved: %+v", set)
	}
}

func TestRunHookRecordsTheSessionOfARun(t *testing.T) {
	s, p := runCLI(t)
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Fix the thing", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got runStartOut
	json.Unmarshal([]byte(out), &got)
	const id = "c57ef956-3136-4e86-bfde-da8facfe0523"
	in := `{"hook_event_name":"SessionStart","session_id":"` + id + `","source":"startup","cwd":"` + got.Run.Folder + `"}`
	if _, _, err := lrRun(t, in, "run", "hook", got.Run.ID); err != nil {
		t.Fatal(err)
	}
	r, err := s.GetRun(got.Run.ID)
	if err != nil || r.SessionID != id {
		t.Fatalf("%+v %v", r, err)
	}
	// The session is a session of the plot, so loam resume finds it.
	rec, err := s.GetSession(id)
	if err != nil || rec.PlotID != p.ID || rec.StartFolder != got.Run.Folder {
		t.Fatalf("%+v %v", rec, err)
	}
}

func containsRun(args, want []string) bool {
	for i := 0; i+len(want) <= len(args); i++ {
		if slices.Equal(args[i:i+len(want)], want) {
			return true
		}
	}
	return false
}

func argAfter(args []string, flag string) string {
	if i := slices.Index(args, flag); i >= 0 && i+1 < len(args) {
		return args[i+1]
	}
	return ""
}

func realPath(t *testing.T, path string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// gateRun starts a run whose one check passes when hello.txt holds "hi there".
func gateRun(t *testing.T, maxTries string) (*store.Store, store.Run) {
	t.Helper()
	s, _ := runCLI(t)
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--max-tries", maxTries,
		"--check", "Hello=grep -qx 'hi there' hello.txt", "--json")
	if err != nil {
		t.Fatal(err)
	}
	var got runStartOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatal(err)
	}
	return s, got.Run
}

// stopHook sends a Stop hook of the run and returns the exit code and stderr.
func stopHook(t *testing.T, r store.Run, event string) (int, string) {
	t.Helper()
	in := `{"hook_event_name":"` + event + `","session_id":"c57ef956-3136-4e86-bfde-da8facfe0523","cwd":"` + r.Folder + `","error":"rate_limit"}`
	_, errOut, err := lrRun(t, in, "run", "hook", r.ID)
	var code exitCode
	switch {
	case err == nil:
		return 0, errOut
	case errors.As(err, &code):
		return int(code), errOut
	}
	t.Fatal(err)
	return 0, ""
}

func writeAndCommit(t *testing.T, dir, file, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, dir, "add", file)
	testutil.Git(t, dir, "commit", "-q", "-m", "Write "+file)
}

func TestRunGateBlocksAStopUntilTheChecksPass(t *testing.T) {
	s, r := gateRun(t, "3")

	code, reason := stopHook(t, r, "Stop")
	if code != 2 || !strings.Contains(reason, "Hello") || !strings.Contains(reason, "grep -qx 'hi there' hello.txt") ||
		!strings.Contains(reason, "try 1 of 3") {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunRunning || got.Tries != 1 {
		t.Fatalf("after a failed gate: %+v", got)
	}

	// Work that is not committed fails the gate, even when the checks pass.
	if err := os.WriteFile(filepath.Join(r.Folder, "hello.txt"), []byte("hi there\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	code, reason = stopHook(t, r, "Stop")
	if code != 2 || !strings.Contains(reason, "Work committed") || !strings.Contains(reason, "hello.txt") {
		t.Fatalf("uncommitted: code %d, reason:\n%s", code, reason)
	}

	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	if code, reason = stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("passing gate: code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunReady || got.Tries != 2 {
		t.Fatalf("after the gate passed: %+v", got)
	}
	events, _ := s.RunEvents(r.ID)
	var passed bool
	for _, e := range events {
		passed = passed || (e.Kind == "check" && strings.HasPrefix(e.Detail, "Hello passed"))
	}
	if !passed {
		t.Fatalf("no check event: %+v", events)
	}
	// A later stop, such as after you type in an attached session, does not
	// run the gate again.
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("stop after Ready: %d", code)
	}
}

func TestRunGateStopsTheRunWhenTheTriesRunOut(t *testing.T) {
	s, r := gateRun(t, "2")
	if code, _ := stopHook(t, r, "Stop"); code != 2 {
		t.Fatalf("try 1: %d", code)
	}
	// The last try lets the session stop, and the run needs you.
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("try 2: %d", code)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunStopped || got.Tries != 2 || !strings.Contains(got.Note, "Hello") {
		t.Fatalf("%+v", got)
	}
}

func TestRunStopFailureFromALimitCountsNoTry(t *testing.T) {
	s, r := gateRun(t, "3")
	if code, _ := stopHook(t, r, "StopFailure"); code != 0 {
		t.Fatalf("code %d", code)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunLimited || got.Tries != 0 || !strings.Contains(got.Note, "rate_limit") {
		t.Fatalf("%+v", got)
	}
}

func TestRunMaxTriesStaysUnderTheBlockCapOfClaudeCode(t *testing.T) {
	runCLI(t)
	_, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--max-tries", "9")
	if !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("err %v", err)
	}
}
