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

// shapeDraft is the result message that claude -p prints for a draft. With
// --output-format stream-json it is the last message.
const shapeDraft = `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {
  "goal": "Loam remembers the window size of each plot.",
  "checks": [{"name": "Window tests", "command": "go test ./window/..."}],
  "assumptions": ["A plot closed in full screen opens in full screen."],
  "plan": ["Save the frame per plot.", "Restore it when the window opens."],
  "size": "About 160 lines in two packages."}}`

type runOut struct {
	Run store.Run `json:"run"`
}

// shapeCLI is runCLI with a fake claude that prints shapeDraft for claude -p.
// It returns the repo.
func shapeCLI(t *testing.T) (*store.Store, store.Plot, string) {
	t.Helper()
	s, p, repo := wtCLI(t)
	testutil.FakeClaude(t)
	trustFolder(t, repo)
	testutil.FakeClaudePrint(t, shapeDraft)
	return s, p, repo
}

func shapeRun(t *testing.T, args ...string) store.Run {
	t.Helper()
	out, errOut, err := lrRun(t, "", append([]string{"run"}, append(args, "--json")...)...)
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var got runOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Run
}

func TestRunShapeDraftsTheGoalAndTheChecksWithClaude(t *testing.T) {
	s, p, repo := shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")

	if r.State != store.RunShaping || r.WorktreeID != "" || realPath(t, r.Folder) != realPath(t, repo) {
		t.Fatalf("run %+v", r)
	}
	if r.Goal != "Loam remembers the window size of each plot." ||
		!slices.Equal(r.DoneWhen, []store.Check{{Name: "Window tests", Command: "go test ./window/..."}}) {
		t.Fatalf("draft %q %+v", r.Goal, r.DoneWhen)
	}
	sh := r.Shape
	if sh == nil || sh.DraftedAt == nil || len(sh.Assumptions) != 1 || sh.Assumptions[0].Text != "A plot closed in full screen opens in full screen." ||
		len(sh.Plan) != 2 || sh.Size != "About 160 lines in two packages." {
		t.Fatalf("shape %+v", sh)
	}

	// Claude reads the repo in print mode, with read-only tools, and answers
	// in the shape of the schema. It starts no background session.
	inv := testutil.FakeClaudeInvocation(t)
	if realPath(t, inv.Cwd) != realPath(t, repo) {
		t.Fatalf("cwd %s", inv.Cwd)
	}
	for _, want := range [][]string{{"-p"}, {"--output-format", "stream-json", "--verbose"}, {"--no-session-persistence"}, {"--tools", "Read,Grep,Glob"},
		{"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`}} {
		if !containsRun(inv.Args, want) {
			t.Errorf("args %q miss %q", inv.Args, want)
		}
	}
	if slices.Contains(inv.Args, "--bg") || !json.Valid([]byte(argAfter(inv.Args, "--json-schema"))) {
		t.Errorf("args %q", inv.Args)
	}
	// The prompt says how a run ends, so no draft plans the commit or the PR.
	if prompt := argAfter(inv.Args, "-p"); !strings.Contains(prompt, "Remember the window size per plot") ||
		!strings.Contains(prompt, "The session commits its work") {
		t.Errorf("prompt %q", prompt)
	}
	if ws, _ := s.ListWorktrees(p.ID); len(ws) != 0 {
		t.Fatalf("a shaping run made a worktree: %+v", ws)
	}
}

// Issue #58: a draft loads only the MCP servers that the run defaults of
// the plot select, each copied from the Claude Code config.
func TestRunShapeLoadsOnlyTheMCPServersOfTheRunDefaults(t *testing.T) {
	_, _, repo := shapeCLI(t)
	server := func(cmd string) map[string]any { return map[string]any{"type": "stdio", "command": cmd} }
	b, _ := json.Marshal(map[string]any{
		"projects":   map[string]any{repo: map[string]bool{"hasTrustDialogAccepted": true}},
		"mcpServers": map[string]any{"loam": server("loam-cmd"), "slack": server("slack-cmd")},
	})
	if err := os.WriteFile(filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), ".claude.json"), b, 0o600); err != nil {
		t.Fatal(err)
	}
	runDefaultsOut(t, "alpha", "--mcp", "loam")
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.Shape.DraftedAt == nil {
		t.Fatalf("no draft: %q", r.Note)
	}
	// The config is a file, not an argument, because a definition can hold a
	// token. Loam removes the file when claude ends.
	inv := testutil.FakeClaudeInvocation(t)
	if !slices.Contains(inv.Args, "--strict-mcp-config") || strings.Contains(strings.Join(inv.Args, " "), "loam-cmd") {
		t.Fatalf("args %q", inv.Args)
	}
	if path := argAfter(inv.Args, "--mcp-config"); !filepath.IsAbs(path) {
		t.Errorf("mcp config path %q", path)
	} else if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("the mcp config file stays: %v", err)
	}
	var config struct {
		MCPServers map[string]struct {
			Command string `json:"command"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal([]byte(inv.MCPConfig), &config); err != nil {
		t.Fatalf("%v: %q", err, inv.MCPConfig)
	}
	if len(config.MCPServers) != 1 || config.MCPServers["loam"].Command != "loam-cmd" {
		t.Fatalf("servers %+v", config.MCPServers)
	}

	// A name that is not in the config stops the draft, and the note names it.
	runDefaultsOut(t, "alpha", "--mcp", "loam,lienar")
	r = shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.Shape.DraftedAt != nil || !strings.Contains(r.Note, `"lienar"`) {
		t.Fatalf("draft %v note %q", r.Shape.DraftedAt, r.Note)
	}
}

// Ticket 207: the steps of a draft stream in. Each step that claude -p takes
// is a draft event, so the desk can show it while Claude drafts.
func TestRunShapeRecordsEachStepOfTheDraft(t *testing.T) {
	s, _, repo := shapeCLI(t)
	steps := []string{
		`{"type": "system", "subtype": "init"}`,
		`{"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "I'll read the window code first.\nThen the tests."}]}}`,
		`{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "` + repo + `/window/frame.go"}}]}}`,
		`{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Grep", "input": {"pattern": "SaveFrame"}}]}}`,
		`{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Glob", "input": {"pattern": "**/*_test.go"}}]}}`,
		`{"type": "user", "message": {"content": [{"type": "tool_result", "content": "..."}]}}`,
		`{"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "StructuredOutput", "input": {}}]}}`,
		strings.ReplaceAll(shapeDraft, "\n", " "),
	}
	testutil.FakeClaudePrint(t, strings.Join(steps, "\n")+"\n")
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.Shape.DraftedAt == nil || r.Goal != "Loam remembers the window size of each plot." {
		t.Fatalf("run %+v", r)
	}
	want := []string{"I'll read the window code first.", "Read window/frame.go", "Searched for SaveFrame",
		"Looked for **/*_test.go", "Wrote the draft"}
	if got := events(t, s, r.ID, "draft"); !slices.Equal(got, want) {
		t.Fatalf("draft events %q, want %q", got, want)
	}
}

func TestRunShapeKeepsTheRunWhenClaudeCannotDraft(t *testing.T) {
	shapeCLI(t)
	testutil.FakeClaudePrint(t, `{"type": "result", "subtype": "error_max_turns", "is_error": true, "result": "Out of turns"}`)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.State != store.RunShaping || r.Shape == nil || r.Shape.DraftedAt != nil || !strings.Contains(r.Note, "Claude could not draft the run") {
		t.Fatalf("run %+v", r)
	}
	// With no draft, there is nothing to approve.
	if _, _, err := lrRun(t, "", "run", "approve", r.ID); err == nil || !strings.Contains(err.Error(), "loam run redraft") {
		t.Fatalf("approved a run with no draft: %v", err)
	}
}

// As for run start: claude -p loads the settings and hooks of the repo with
// no trust prompt, so Loam does not run it in a folder that Claude Code does
// not trust.
func TestRunShapeDoesNotDraftInAFolderThatClaudeCodeDoesNotTrust(t *testing.T) {
	shapeCLI(t)
	trustFolder(t, "")
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if r.State != store.RunShaping || r.Shape.DraftedAt != nil || !strings.Contains(r.Note, "does not trust") {
		t.Fatalf("run %+v", r)
	}
	if calls := testutil.FakeClaudeCalls(t); len(calls) != 0 {
		t.Fatalf("claude calls %q", calls)
	}
}

func TestRunShapeGivesClaudeTheTextOfTheTicket(t *testing.T) {
	_, _, _, issues := intakeCLI(t)
	testutil.FakeClaudePrint(t, shapeDraft)
	ticket := filepath.Join(issues, "135-quit-during-a-merge.md")
	r := shapeRun(t, "shape", "alpha", "--title", "Quit during a merge", "--ticket", ticket)
	if r.Source == nil || r.Source.Key != "map 135" {
		t.Fatalf("source %+v", r.Source)
	}
	prompt := argAfter(testutil.FakeClaudeInvocation(t).Args, "-p")
	if !strings.Contains(prompt, "# Driver scenario: quit during a merge") {
		t.Fatalf("prompt misses the ticket:\n%s", prompt)
	}
}

func TestRunRedraftSendsYourChangeWithTheLastDraft(t *testing.T) {
	shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	testutil.FakeClaudePrint(t, strings.Replace(shapeDraft, "two packages", "three packages", 1))
	r = shapeRun(t, "redraft", r.ID, "--change", "Add a check for two screens")
	if r.State != store.RunShaping || r.Shape.Size != "About 160 lines in three packages." {
		t.Fatalf("run %+v", r)
	}
	prompt := argAfter(testutil.FakeClaudeInvocation(t).Args, "-p")
	for _, want := range []string{"Add a check for two screens", "Loam remembers the window size of each plot."} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
}

func TestRunApproveStartsTheShapedRunWithYourEdits(t *testing.T) {
	_, _, _ = shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	r = shapeRun(t, "approve", r.ID, "--goal", "Loam remembers the window size and place of each plot.",
		"--answer", "1=A plot closed in full screen opens in a normal window.")

	if r.State != store.RunRunning || r.WorktreeID == "" || r.Goal != "Loam remembers the window size and place of each plot." {
		t.Fatalf("run %+v", r)
	}
	// With no --check, the drafted checks stay.
	if len(r.DoneWhen) != 1 || r.DoneWhen[0].Name != "Window tests" {
		t.Fatalf("checks %+v", r.DoneWhen)
	}
	if a := r.Shape.Assumptions[0]; a.Answer != "A plot closed in full screen opens in a normal window." {
		t.Fatalf("assumption %+v", a)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if !slices.Contains(inv.Args, "--bg") || realPath(t, inv.Cwd) != realPath(t, r.Folder) {
		t.Fatalf("args %q in %s", inv.Args, inv.Cwd)
	}
	prompt := inv.Args[len(inv.Args)-1]
	for _, want := range []string{"Loam remembers the window size and place of each plot.", "Save the frame per plot.",
		"A plot closed in full screen opens in a normal window.", "go test ./window/..."} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "opens in full screen") {
		t.Errorf("the prompt keeps the assumption that you changed:\n%s", prompt)
	}

	// A run that is not Shaping is not approved again.
	if _, _, err := lrRun(t, "", "run", "approve", r.ID); err == nil {
		t.Fatal("approved a running run")
	}
}

func TestRunApproveReplacesTheChecksWithYours(t *testing.T) {
	shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if _, _, err := lrRun(t, "", "run", "approve", r.ID, "--answer", "9=No"); err == nil || !strings.Contains(err.Error(), "no assumption 9") {
		t.Fatalf("an answer to no assumption passed: %v", err)
	}
	r = shapeRun(t, "approve", r.ID, "--check", "All tests=go test ./...")
	if !slices.Equal(r.DoneWhen, []store.Check{{Name: "All tests", Command: "go test ./..."}}) {
		t.Fatalf("checks %+v", r.DoneWhen)
	}
}

func TestRunApproveWithNoChecksRemovesTheDraftedChecks(t *testing.T) {
	shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if _, _, err := lrRun(t, "", "run", "approve", r.ID, "--no-checks", "--check", "All tests=go test ./..."); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("--no-checks with --check: %v", err)
	}
	// The default checks of the plot do not come back: a person asked for none.
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--check", "Plot=go test ./..."); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	r = shapeRun(t, "approve", r.ID, "--no-checks")
	if r.State != store.RunRunning || len(r.DoneWhen) != 0 {
		t.Fatalf("run %+v", r)
	}
}

func TestRunCancelOfAShapingRunCancelsItWithoutClaude(t *testing.T) {
	shapeCLI(t)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	calls := len(testutil.FakeClaudeCalls(t))
	r = shapeRun(t, "cancel", r.ID)
	if r.State != store.RunCancelled || len(testutil.FakeClaudeCalls(t)) != calls {
		t.Fatalf("run %+v, claude calls %q", r, testutil.FakeClaudeCalls(t))
	}
}
