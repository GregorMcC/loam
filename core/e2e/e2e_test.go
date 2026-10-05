//go:build e2e

// Package e2e runs the real claude against a built loam. It costs usage, so
// it sits behind the e2e build tag. Run it at phase gates:
//
//	go test -tags e2e ./e2e/
//
// Each case starts one session through `loam start`, in print mode with
// stream-json input, on the haiku model. A stub MCP server provides the
// permission prompt tool, so a logged call means Claude Code would ask.
package e2e

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

const turnTimeout = 150 * time.Second

type rig struct {
	home  string
	loam  string
	stub  string
	log   string // stub log path
	store *store.Store
	repo  string
}

func newRig(t *testing.T) *rig {
	t.Helper()
	if _, err := exec.LookPath("claude"); err != nil {
		t.Skip("claude is not on PATH")
	}
	home := testutil.Home(t)
	r := &rig{home: home, loam: testutil.BuildLoam(t), log: filepath.Join(t.TempDir(), "stub.log"), repo: t.TempDir()}
	r.stub = filepath.Join(t.TempDir(), "stub")
	if out, err := exec.Command("go", "build", "-o", r.stub, "github.com/GregorMcC/loam/core/e2e/stub").CombinedOutput(); err != nil {
		t.Fatalf("build stub: %v\n%s", err, out)
	}
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	r.store = s
	return r
}

func (r *rig) plot(t *testing.T, what string) store.Plot {
	t.Helper()
	res, err := r.store.CreatePlot(store.PlotInput{
		Name: "E2E plot", What: what, Why: "To test Loam.", Where: "Waiting for the test.",
		Repos: []store.RepoInput{{Path: r.repo}},
	}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	return res.Plot
}

// approvals returns the tool names that the stub logged.
func (r *rig) approvals(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile(r.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var e struct {
			ToolName string `json:"tool_name"`
		}
		if json.Unmarshal([]byte(l), &e) == nil && e.ToolName != "" {
			names = append(names, e.ToolName)
		}
	}
	return names
}

// cleanEnv drops the variables that a parent Claude Code session sets.
func cleanEnv(env []string) []string {
	var out []string
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if k == "CLAUDECODE" || strings.HasPrefix(k, "CLAUDE_CODE_") || k == "CLAUDE_PID" ||
			k == "CLAUDE_EFFORT" || k == "CLAUDE_PROJECT_DIR" || k == "LOAM_PLOT" {
			continue
		}
		out = append(out, kv)
	}
	return out
}

type event map[string]any

func (e event) str(k string) string { s, _ := e[k].(string); return s }

// toolUses returns the names of the tools that the events call.
func toolUses(evs []event) []string {
	var names []string
	for _, e := range evs {
		if e.str("type") != "assistant" {
			continue
		}
		msg, _ := e["message"].(map[string]any)
		content, _ := msg["content"].([]any)
		for _, c := range content {
			if m, ok := c.(map[string]any); ok && m["type"] == "tool_use" {
				n, _ := m["name"].(string)
				names = append(names, n)
			}
		}
	}
	return names
}

// toolResultErrors counts tool results that are errors.
func toolResultErrors(evs []event) int {
	n := 0
	for _, e := range evs {
		if e.str("type") != "user" {
			continue
		}
		msg, _ := e["message"].(map[string]any)
		content, _ := msg["content"].([]any)
		for _, c := range content {
			if m, ok := c.(map[string]any); ok && m["type"] == "tool_result" && m["is_error"] == true {
				n++
			}
		}
	}
	return n
}

type session struct {
	t      *testing.T
	cmd    *exec.Cmd
	stdin  interface{ Write([]byte) (int, error) }
	closeF func()
	events chan event
	stderr *bytes.Buffer
}

// start runs `loam start` with the print-mode args from LOAM_CLAUDE_EXTRA_ARGS.
func (r *rig) start(t *testing.T, plot store.Plot, sessionID string) *session {
	t.Helper()
	cfg := map[string]any{"mcpServers": map[string]any{
		"loam": map[string]any{"command": r.loam, "args": []string{"mcp"}, "env": map[string]string{"LOAM_HOME": r.home}},
		"stub": map[string]any{"command": r.stub, "env": map[string]string{"STUB_LOG": r.log}},
	}}
	b, _ := json.Marshal(cfg)
	cfgPath := filepath.Join(t.TempDir(), "mcp.json")
	if err := os.WriteFile(cfgPath, b, 0o644); err != nil {
		t.Fatal(err)
	}
	extra, _ := json.Marshal([]string{
		"-p", "--model", "haiku",
		"--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
		"--mcp-config", cfgPath, "--strict-mcp-config",
		"--permission-prompt-tool", "mcp__stub__approve",
		// Haiku sometimes ran `loam` through Bash. The suite checks the loam
		// MCP tools, so Bash is not available to the session.
		"--disallowedTools", "Bash",
	})
	cmd := exec.Command(r.loam, "start", plot.ID, "--session-id", sessionID)
	cmd.Env = append(cleanEnv(os.Environ()), "LOAM_CLAUDE_EXTRA_ARGS="+string(extra))
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	s := &session{t: t, cmd: cmd, stdin: in, closeF: func() { in.Close() }, events: make(chan event, 1024), stderr: &bytes.Buffer{}}
	cmd.Stderr = s.stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	go func() {
		sc := bufio.NewScanner(out)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for sc.Scan() {
			var e event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				s.events <- e
			}
		}
		close(s.events)
	}()
	t.Cleanup(func() {
		s.closeF()
		done := make(chan struct{})
		go func() { cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	})
	return s
}

// turn sends one user message and returns the events up to its result.
func (s *session) turn(text string) []event {
	s.t.Helper()
	line, _ := json.Marshal(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": text}})
	if _, err := s.stdin.Write(append(line, '\n')); err != nil {
		s.t.Fatalf("write turn: %v\nstderr: %s", err, s.stderr)
	}
	var evs []event
	timeout := time.After(turnTimeout)
	for {
		select {
		case e, ok := <-s.events:
			if !ok {
				s.t.Fatalf("claude exited before the result of %q\nstderr: %s", text, s.stderr)
			}
			evs = append(evs, e)
			if e.str("type") == "result" {
				return evs
			}
		case <-timeout:
			s.t.Fatalf("no result for %q within %s\nstderr: %s", text, turnTimeout, s.stderr)
		}
	}
}

func result(evs []event) event { return evs[len(evs)-1] }

const sessionA = "aaaaaaaa-1111-4222-8333-444444444444"

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func TestSeedLoads(t *testing.T) {
	r := newRig(t)
	p := r.plot(t, "The codeword of this plot is zebra-quartz-77.")
	s := r.start(t, p, sessionA)
	evs := s.turn("Do not use any tools. State the brief of this plot, including its codeword.")
	res := result(evs)
	if got := res.str("result"); !strings.Contains(got, "zebra-quartz-77") {
		t.Errorf("the session did not state the brief: %q", got)
	}
	if tools := toolUses(evs); len(tools) > 0 {
		t.Errorf("the session used tools: %v", tools)
	}
}

func TestAllowToolRunsWithoutPrompt(t *testing.T) {
	r := newRig(t)
	p := r.plot(t, "Plot for the allow test.")
	s := r.start(t, p, sessionA)
	evs := s.turn("Call the mcp__loam__list_plots tool once. Then reply with the plot ID only.")
	if !contains(toolUses(evs), "mcp__loam__list_plots") {
		t.Errorf("list_plots was not called: %v", toolUses(evs))
	}
	if n := toolResultErrors(evs); n > 0 {
		t.Errorf("%d tool results are errors", n)
	}
	if a := r.approvals(t); len(a) > 0 {
		t.Errorf("an allow tool prompted: %v", a)
	}
	if got := result(evs).str("result"); !strings.Contains(got, p.ID) {
		t.Errorf("the reply %q does not hold the plot ID %s", got, p.ID)
	}
}

// TestAskToolPrompts: a write tool has no rule (ticket 84), so outside auto
// mode Claude Code still asks. Print mode is not auto mode.
func TestAskToolPrompts(t *testing.T) {
	r := newRig(t)
	p := r.plot(t, "Plot for the ask test.")
	s := r.start(t, p, sessionA)
	s.turn("Call mcp__loam__get_plot for plot " + p.ID + ". Then call mcp__loam__set_where_it_stands for that plot with the text \"e2e ask test\". Reply done.")
	if a := r.approvals(t); !contains(a, "mcp__loam__set_where_it_stands") {
		t.Errorf("set_where_it_stands did not prompt: %v", a)
	}
	got, err := r.store.GetPlot(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Where != "Waiting for the test." {
		t.Errorf("the denied write changed the brief: %q", got.Where)
	}
}

func TestClearRecordsNewSessionID(t *testing.T) {
	r := newRig(t)
	p := r.plot(t, "Plot for the clear test.")
	s := r.start(t, p, sessionA)
	s.turn("Call mcp__loam__get_plot for plot " + p.ID + ". Reply ok.")
	s.turn("/clear")
	evs := s.turn("Call mcp__loam__get_plot for plot " + p.ID + " again. Then call mcp__loam__add_link for that plot with label \"e2e\" and target \"https://example.com\". Reply done.")
	newID := result(evs).str("session_id")
	if newID == "" || newID == sessionA {
		t.Fatalf("/clear did not give a new session ID: %q", newID)
	}
	if a := r.approvals(t); len(a) > 0 {
		t.Errorf("add_link prompted: %v", a)
	}
	changes, err := r.store.ListChanges(store.ChangeQuery{PlotID: p.ID, Limit: 1, Newest: true})
	if err != nil || len(changes) == 0 {
		t.Fatalf("no change: %v", err)
	}
	c := changes[0]
	if c.Actor.Kind != store.ActorSession || c.Actor.SessionID != newID {
		t.Errorf("change actor %+v, want session %s", c.Actor, newID)
	}
}
