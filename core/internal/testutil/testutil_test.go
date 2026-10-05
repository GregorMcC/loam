package testutil_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestHomeSetsLoamHome(t *testing.T) {
	dir := testutil.Home(t)
	if os.Getenv("LOAM_HOME") != dir {
		t.Fatal("LOAM_HOME is not set")
	}
}

func TestFakeClaudeRecordsArgvEnvAndFolder(t *testing.T) {
	testutil.FakeClaude(t)
	work := t.TempDir()
	cmd := exec.Command("claude", "--session-id", "abc")
	cmd.Dir = work
	cmd.Env = append(os.Environ(), "LOAM_PLOT=p1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	inv := testutil.FakeClaudeInvocation(t)
	want, _ := filepath.EvalSymlinks(work)
	got, _ := filepath.EvalSymlinks(inv.Cwd)
	if got != want || inv.Env["LOAM_PLOT"] != "p1" || len(inv.Args) != 2 || inv.Args[1] != "abc" {
		t.Fatalf("invocation %+v", inv)
	}
}

// hookSettings writes a settings file whose hook for each event appends the
// hook JSON and a newline to log.
func hookSettings(t *testing.T, log string) string {
	t.Helper()
	cmd := "cat >> '" + log + "'; echo >> '" + log + "'"
	hooks := map[string]any{}
	for _, e := range []string{"SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
		"PermissionRequest", "Notification", "PostToolUse", "StopFailure"} {
		hooks[e] = []any{map[string]any{"hooks": []any{map[string]any{"type": "command", "command": cmd}}}}
	}
	b, _ := json.Marshal(map[string]any{"hooks": hooks})
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

type hookCall struct {
	Event            string `json:"hook_event_name"`
	SessionID        string `json:"session_id"`
	Source           string `json:"source"`
	Cwd              string `json:"cwd"`
	NotificationType string `json:"notification_type"`
}

func readHookCalls(t *testing.T, log string) []hookCall {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	var calls []hookCall
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		var c hookCall
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		calls = append(calls, c)
	}
	return calls
}

func TestFakeClaudeHookModeRunsTheSettingsHooks(t *testing.T) {
	testutil.FakeClaude(t)
	log := filepath.Join(t.TempDir(), "hooks.log")
	cmd := exec.Command("claude", "--session-id", "s1", "--settings", hookSettings(t, log))
	cmd.Env = append(os.Environ(), "LOAM_FAKE_CLAUDE_HOOKS=1", "LOAM_FAKE_CLAUDE_TURN=10ms")
	cmd.Stdin = strings.NewReader("hello\n/clear\n/exit\n")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	calls := readHookCalls(t, log)
	var got []string
	for _, c := range calls {
		got = append(got, c.Event+" "+c.Source)
	}
	want := []string{"SessionStart startup", "UserPromptSubmit ", "Stop ", "SessionEnd ", "SessionStart clear", "SessionEnd "}
	if !slices.Equal(got, want) {
		t.Fatalf("hooks %q, want %q", got, want)
	}
	if calls[0].SessionID != "s1" || calls[3].SessionID != "s1" || calls[0].Cwd == "" {
		t.Fatalf("first session: %+v", calls)
	}
	if calls[4].SessionID == "s1" || calls[4].SessionID == "" || calls[5].SessionID != calls[4].SessionID {
		t.Fatalf("/clear did not change the session ID: %+v", calls)
	}
}

// The lines that make the session wait on you: a permission prompt that you
// allow or deny, a question, and a turn that stops on an API error.
func TestFakeClaudeHookModeRaisesTheNeedsYouHooks(t *testing.T) {
	testutil.FakeClaude(t)
	log := filepath.Join(t.TempDir(), "hooks.log")
	cmd := exec.Command("claude", "--session-id", "s1", "--settings", hookSettings(t, log))
	cmd.Env = append(os.Environ(), "LOAM_FAKE_CLAUDE_HOOKS=1", "LOAM_FAKE_CLAUDE_TURN=10ms")
	cmd.Stdin = strings.NewReader("/permission\ny\n/permission\nn\n/question\nblue\n/paused\nok\n/fail\n/exit\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	var got []string
	for _, c := range readHookCalls(t, log) {
		got = append(got, strings.TrimSpace(c.Event+" "+c.NotificationType))
	}
	want := []string{"SessionStart",
		"UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", // allowed
		"UserPromptSubmit", "PermissionRequest", // denied: no hook follows
		"UserPromptSubmit", "Notification elicitation_dialog", "PostToolUse", "Stop",
		"UserPromptSubmit", "Notification permission_prompt", "PostToolUse", "Stop",
		"UserPromptSubmit", "StopFailure",
		"SessionEnd"}
	if !slices.Equal(got, want) {
		t.Fatalf("hooks %q, want %q", got, want)
	}
	for _, text := range []string{"fake claude: allow? (y/n)", "fake claude: denied", "fake claude: question", "fake claude: API error"} {
		if !strings.Contains(string(out), text) {
			t.Fatalf("the output has no %q:\n%s", text, out)
		}
	}
}

func TestFakeClaudeHookModeResumesWithTheGivenID(t *testing.T) {
	testutil.FakeClaude(t)
	log := filepath.Join(t.TempDir(), "hooks.log")
	cmd := exec.Command("claude", "--resume", "r1", "--settings", hookSettings(t, log))
	cmd.Env = append(os.Environ(), "LOAM_FAKE_CLAUDE_HOOKS=1")
	cmd.Stdin = strings.NewReader("") // EOF ends the session.
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	calls := readHookCalls(t, log)
	if len(calls) != 2 || calls[0].Event != "SessionStart" || calls[0].Source != "resume" || calls[0].SessionID != "r1" || calls[1].Event != "SessionEnd" {
		t.Fatalf("hooks %+v", calls)
	}
}

func TestFakeClaudeHupWaitDelaysTheExit(t *testing.T) {
	testutil.FakeClaude(t)
	cmd := exec.Command("claude", "--session-id", "h1")
	cmd.Env = append(os.Environ(), "LOAM_FAKE_CLAUDE_HOOKS=1", "LOAM_FAKE_CLAUDE_HUP_WAIT=300ms")
	stdin, err := cmd.StdinPipe() // Open stdin keeps the session alive.
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// The fake installs the SIGHUP handler before it writes the invocation file.
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			t.Fatal("the fake claude did not start")
		}
	}
	start := time.Now()
	if err := cmd.Process.Signal(syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("exit after SIGHUP: %v", err)
	}
	if waited := time.Since(start); waited < 300*time.Millisecond {
		t.Fatalf("the process exited %v after SIGHUP, want at least 300ms", waited)
	}
}

func TestFakeClaudeHupWaitDelaysTheExitAfterEOF(t *testing.T) {
	testutil.FakeClaude(t)
	cmd := exec.Command("claude", "--session-id", "h2")
	cmd.Env = append(os.Environ(), "LOAM_FAKE_CLAUDE_HOOKS=1", "LOAM_FAKE_CLAUDE_HUP_WAIT=300ms")
	cmd.Stdin = strings.NewReader("") // EOF at once, as after a revoked terminal.
	start := time.Now()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if waited := time.Since(start); waited < 300*time.Millisecond {
		t.Fatalf("the process exited %v after EOF, want at least 300ms", waited)
	}
}
