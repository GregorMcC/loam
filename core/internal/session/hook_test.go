package session_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func runHook(t *testing.T, stdin string, env map[string]string) string {
	t.Helper()
	var out bytes.Buffer
	session.RunHook(strings.NewReader(stdin), &out, func(k string) string { return env[k] })
	return out.String()
}

func TestHookCompactPrintsSeed(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha", What: "the what"})
	if err := os.WriteFile(filepath.Join(e.home, "plots", p.ID, "CLAUDE.md"), []byte("SEED TEXT\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := runHook(t, `{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}`,
		map[string]string{"LOAM_PLOT": p.ID, "CLAUDE_PID": "4242"})
	var got struct {
		HookSpecificOutput struct{ HookEventName, AdditionalContext string }
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("output %q: %v", out, err)
	}
	if got.HookSpecificOutput.HookEventName != "SessionStart" || got.HookSpecificOutput.AdditionalContext != "SEED TEXT\n" {
		t.Errorf("got %+v", got)
	}
}

func TestHookStartupPrintsNothingAndRecordsPID(t *testing.T) {
	e := setup(t)
	p := e.plot(t, store.PlotInput{Name: "Alpha"})
	out := runHook(t, `{"session_id":"s-new","source":"startup"}`, map[string]string{"LOAM_PLOT": p.ID, "CLAUDE_PID": "4242"})
	if out != "" {
		t.Errorf("output %q", out)
	}
	id, ok, err := e.store.SessionForPID(4242)
	if err != nil || !ok || id != "s-new" {
		t.Errorf("pid record %q %v %v", id, ok, err)
	}
	// /clear moves the PID to the new session.
	runHook(t, `{"session_id":"s-clear","source":"clear"}`, map[string]string{"CLAUDE_PID": "4242"})
	if id, _, _ := e.store.SessionForPID(4242); id != "s-clear" {
		t.Errorf("pid record %q after clear", id)
	}
}

func TestHookCompactAlsoRecordsPID(t *testing.T) {
	e := setup(t)
	runHook(t, `{"session_id":"s2","source":"compact"}`, map[string]string{"CLAUDE_PID": "77"})
	if id, _, _ := e.store.SessionForPID(77); id != "s2" {
		t.Errorf("pid record %q", id)
	}
}

func TestHookBadInputNeverFailsAndLogs(t *testing.T) {
	e := setup(t)
	for _, in := range []string{"", "not json", `{"session_id":`, `[]`} {
		if out := runHook(t, in, map[string]string{"CLAUDE_PID": "5", "LOAM_PLOT": "zzzzzzzzzz"}); out != "" {
			t.Errorf("input %q: output %q", in, out)
		}
	}
	b, err := os.ReadFile(filepath.Join(e.home, "hook.log"))
	if err != nil || len(b) == 0 {
		t.Errorf("no log: %v", err)
	}
}

func TestHookMissingStoreDoesNotFail(t *testing.T) {
	testutil.Home(t)
	// A file where the home folder must be, so the store cannot open.
	blocker := filepath.Join(t.TempDir(), "blocker")
	if err := os.WriteFile(blocker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_HOME", filepath.Join(blocker, "home"))
	out := runHook(t, `{"session_id":"s","source":"compact"}`, map[string]string{"LOAM_PLOT": "aaaaaaaaaa", "CLAUDE_PID": "9"})
	if out != "" {
		t.Errorf("output %q", out)
	}
}

func TestHookCompactMissingSeedPrintsNothing(t *testing.T) {
	setup(t)
	if out := runHook(t, `{"session_id":"s","source":"compact"}`, map[string]string{"LOAM_PLOT": "aaaaaaaaaa"}); out != "" {
		t.Errorf("output %q", out)
	}
}

func TestHookDoesNotCreateAStore(t *testing.T) {
	home := testutil.Home(t)
	runHook(t, `{"session_id":"s","source":"startup"}`, map[string]string{"CLAUDE_PID": "9"})
	if _, err := os.Stat(filepath.Join(home, "loam.db")); err == nil {
		t.Error("the hook created a store")
	}
}

func TestHookRejectsPlotIDWithPathParts(t *testing.T) {
	e := setup(t)
	if err := os.WriteFile(filepath.Join(e.home, "CLAUDE.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if out := runHook(t, `{"source":"compact"}`, map[string]string{"LOAM_PLOT": ".."}); out != "" {
		t.Errorf("output %q", out)
	}
}
