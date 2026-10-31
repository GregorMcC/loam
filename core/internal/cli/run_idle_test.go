package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-198: a Stop hook that cannot record the end of a turn, such as on a
// full disk, leaves the run Running with an idle session. A tick stops it,
// so send-back can start it again.

// idleRun is a Running run whose session started, and claude agents with
// the session in state. An empty state leaves the session out of the list.
func idleRun(t *testing.T, state string) (*store.Store, store.Run) {
	t.Helper()
	s, r := gateRun(t, "3")
	stopHook(t, r, "SessionStart")
	agents := `[{"sessionId": "11111111-2222-3333-4444-555555555555", "state": "working"}]`
	if state != "" {
		agents = fmt.Sprintf(`[{"sessionId": %q, "state": %q}]`, shipSession, state)
	}
	testutil.FakeClaudeAgents(t, agents)
	r, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if r.State != store.RunRunning || r.SessionID != shipSession {
		t.Fatalf("not running with the session: %+v", r)
	}
	return s, r
}

// idleWait sets run.IdleWait for the test.
func idleWait(t *testing.T, wait time.Duration) {
	t.Helper()
	old := run.IdleWait
	run.IdleWait = wait
	t.Cleanup(func() { run.IdleWait = old })
}

func agentsCalls(t *testing.T) int {
	t.Helper()
	n := 0
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Equal(c, []string{"agents", "--json", "--all"}) {
			n++
		}
	}
	return n
}

func TestRunTickStopsARunningRunWhoseSessionIsIdle(t *testing.T) {
	for name, state := range map[string]string{"done": "done", "stopped": "stopped", "not listed": ""} {
		t.Run(name, func(t *testing.T) {
			idleWait(t, 0)
			s, r := idleRun(t, state)
			got := tick(t)
			if len(got.Runs) != 1 || got.Runs[0].ID != r.ID || got.Runs[0].State != store.RunStopped || got.Runs[0].Note != run.IdleNote {
				t.Fatalf("%+v", got)
			}
			if r, _ = s.GetRun(r.ID); r.State != store.RunStopped || r.Tries != 0 {
				t.Fatalf("%+v", r)
			}
			if e := events(t, s, r.ID, "state"); len(e) == 0 || e[len(e)-1] != string(store.RunStopped) {
				t.Fatalf("state events %q", e)
			}
			if n := agentsCalls(t); n != 1 {
				t.Fatalf("%d claude agents calls, want 1", n)
			}
		})
	}
}

func TestRunTickKeepsARunWhoseSessionIsInATurn(t *testing.T) {
	for _, state := range []string{"working", "blocked", "thinking"} {
		t.Run(state, func(t *testing.T) {
			idleWait(t, 0)
			s, r := idleRun(t, state)
			if got := tick(t); len(got.Runs) != 0 || len(got.Warnings) != 0 {
				t.Fatalf("%+v", got)
			}
			if r, _ = s.GetRun(r.ID); r.State != store.RunRunning {
				t.Fatalf("%+v", r)
			}
		})
	}
}

// A run that changed in the last 10 minutes waits, and the tick does not
// call claude agents for it.
func TestRunTickKeepsARunThatChangedInTheLastTenMinutes(t *testing.T) {
	if run.IdleWait != 10*time.Minute {
		t.Fatalf("IdleWait %v, want 10m", run.IdleWait)
	}
	s, r := idleRun(t, "done")
	if got := tick(t); len(got.Runs) != 0 || len(got.Warnings) != 0 {
		t.Fatalf("%+v", got)
	}
	if r, _ = s.GetRun(r.ID); r.State != store.RunRunning {
		t.Fatalf("%+v", r)
	}
	if n := agentsCalls(t); n != 0 {
		t.Fatalf("%d claude agents calls, want 0", n)
	}
}

// A check can run for up to 10 minutes with no event, while claude agents
// shows the session as done. A tick during the gate leaves the run to the
// Stop hook, which then records the gate.
func TestRunTickKeepsARunWhoseStopHookRunsTheGate(t *testing.T) {
	idleWait(t, 0)
	s, _ := runCLI(t)
	signals := t.TempDir()
	started, release := filepath.Join(signals, "started"), filepath.Join(signals, "go")
	out, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "Say hi", "--json",
		"--check", fmt.Sprintf("Slow=touch %q && while [ ! -f %q ]; do sleep 0.05; done", started, release))
	if err != nil {
		t.Fatal(err)
	}
	var start runStartOut
	if err := json.Unmarshal([]byte(out), &start); err != nil {
		t.Fatal(err)
	}
	r := start.Run
	stopHook(t, r, "SessionStart")
	testutil.FakeClaudeAgents(t, fmt.Sprintf(`[{"sessionId": %q, "state": "done"}]`, shipSession))
	hook := make(chan error, 1)
	go func() {
		_, _, err := lrRun(t, `{"hook_event_name":"Stop","session_id":"`+shipSession+`","cwd":"`+r.Folder+`"}`, "run", "hook", r.ID)
		hook <- err
	}()
	for deadline := time.Now().Add(10 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(started); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the check did not start")
		}
	}
	if got := tick(t); len(got.Runs) != 0 || len(got.Warnings) != 0 {
		t.Fatalf("the tick moved a run during its gate: %+v", got)
	}
	if err := os.WriteFile(release, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := <-hook; err != nil {
		t.Fatal(err)
	}
	if r, _ = s.GetRun(r.ID); r.Note == run.IdleNote || r.Turns != 1 {
		t.Fatalf("the hook did not record the gate: %+v", r)
	}
}

// A list that Loam cannot read stops no run: a session that the list does
// not have counts as idle.
func TestRunTickWarnsWhenClaudeAgentsGivesNoList(t *testing.T) {
	cases := map[string]string{
		"not json": "not json",
		"null":     "null",
	}
	for name, text := range cases {
		t.Run(name, func(t *testing.T) {
			idleWait(t, 0)
			s, r := idleRun(t, "done")
			testutil.FakeClaudeAgents(t, text)
			if got := tick(t); len(got.Runs) != 0 || len(got.Warnings) != 1 {
				t.Fatalf("%+v", got)
			}
			if r, _ = s.GetRun(r.ID); r.State != store.RunRunning {
				t.Fatalf("%+v", r)
			}
		})
	}
}

// claude agents gives a sessionId only when the session has one. A session
// with none can be the session of the run, so a run that the list does not
// name waits. A run that the list names as done still stops.
func TestRunTickReadsASessionWithNoSessionIdAsAnySession(t *testing.T) {
	unnamed := `{"state": "working"}`
	cases := map[string]struct {
		agents string
		want   store.RunState
	}{
		"not named":   {`[` + unnamed + `]`, store.RunRunning},
		"named, done": {fmt.Sprintf(`[%s, {"sessionId": %q, "state": "done"}]`, unnamed, shipSession), store.RunStopped},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			idleWait(t, 0)
			s, r := idleRun(t, "done")
			testutil.FakeClaudeAgents(t, c.agents)
			if got := tick(t); len(got.Warnings) != 0 {
				t.Fatalf("%+v", got)
			}
			if r, _ = s.GetRun(r.ID); r.State != c.want {
				t.Fatalf("state %s, want %s: %+v", r.State, c.want, r)
			}
		})
	}
}

func TestRunSendBackStartsARunThatTheTickStoppedAsIdle(t *testing.T) {
	idleWait(t, 0)
	_, r := idleRun(t, "done")
	tick(t)
	got, code, out := sendBack(t, r.ID, "--note", "Run the checks again.")
	if code != 0 || got.State != store.RunRunning {
		t.Fatalf("exit %d: %s", code, out)
	}
	if prompt := lastPrompt(t); !strings.Contains(prompt, "- Run the checks again.") {
		t.Fatalf("the prompt misses the note:\n%s", prompt)
	}
}
