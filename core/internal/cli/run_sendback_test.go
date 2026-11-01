package cli

import (
	"encoding/json"
	"os"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ticket 207: Send back. Your notes on the work of a run go back to its
// session, and the run goes round the gate and Ship again.

func sendBack(t *testing.T, args ...string) (store.Run, int, string) {
	t.Helper()
	out, code := loam(t, append([]string{"run", "send-back"}, append(args, "--json")...)...)
	var got struct {
		Run store.Run `json:"run"`
	}
	if code == 0 {
		if err := json.Unmarshal([]byte(out), &got); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	return got.Run, code, out
}

// lastPrompt is the prompt of the last claude --bg --resume.
func lastPrompt(t *testing.T) string {
	t.Helper()
	calls := testutil.FakeClaudeCalls(t)
	n := len(calls)
	if n < 2 || !slices.Equal(calls[n-2], []string{"stop", shipSession[:8]}) || len(calls[n-1]) < 4 ||
		!slices.Equal(calls[n-1][:3], []string{"--bg", "--resume", shipSession}) {
		t.Fatalf("claude calls %q", calls)
	}
	return calls[n-1][len(calls[n-1])-1]
}

// TAS-201: claude --resume keeps no options of the session. So the resume
// passes the settings of the run again: the sandbox, and the hooks that run
// the gate. With no settings, the session would work as you, with no gate.
func TestRunSendBackResumesWithTheSandboxAndTheHooksOfTheRun(t *testing.T) {
	_, r, _ := readyRun(t)
	if _, code, out := sendBack(t, r.ID, "--note", "Add a test."); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	calls := testutil.FakeClaudeCalls(t)
	c := calls[len(calls)-1]
	i := slices.Index(c, "--settings")
	if i < 0 || !slices.Contains(c, "auto") || !slices.Contains(c, "--add-dir") {
		t.Fatalf("resume %q, want the options of the run", c)
	}
	b, err := os.ReadFile(c[i+1])
	if err != nil {
		t.Fatal(err)
	}
	var settings struct {
		Sandbox struct {
			Enabled bool `json:"enabled"`
		} `json:"sandbox"`
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(b, &settings); err != nil {
		t.Fatal(err)
	}
	if !settings.Sandbox.Enabled {
		t.Errorf("the resume has no sandbox: %s", b)
	}
	for _, e := range []string{"SessionStart", "Stop"} {
		if g := settings.Hooks[e]; len(g) == 0 || len(g[0].Hooks) == 0 || !strings.HasSuffix(g[0].Hooks[0].Command, " run hook "+r.ID) {
			t.Errorf("the resume has no %s hook of the run: %s", e, b)
		}
	}
}

func TestRunSendBackResumesTheSessionWithYourNotes(t *testing.T) {
	s, r, _ := readyRun(t)
	got, code, out := sendBack(t, r.ID, "--note", "hello.txt:1: Say hello to the world.", "--note", "Add a test.")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	// A note is not a failure, so it uses no try.
	if got.State != store.RunRunning || got.Tries != r.Tries || got.Note != "Sent back with 2 notes" {
		t.Fatalf("%+v", got)
	}
	prompt := lastPrompt(t)
	for _, want := range []string{"2 notes", "#1", "- hello.txt line 1: Say hello to the world.", "- Add a test.", "commit"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	if e := events(t, s, r.ID, "review"); !slices.Contains(e, "Sent back 2 notes") {
		t.Fatalf("review events %q", e)
	}
	// The change goes round the gate and on to the same PR.
	writeAndCommit(t, r.Folder, "hello_test.txt", "a test\n")
	if code, reason := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("gate: %d %s", code, reason)
	}
	tick(t)
	if e := events(t, s, r.ID, "ship"); !slices.Contains(e, "Pushed the fix to #1") || len(ghCreates(t)) != 1 {
		t.Fatalf("ship events %q", e)
	}
}

func TestRunSendBackGivesAStoppedRunOneMoreTry(t *testing.T) {
	_, r, w := shipRun(t, "1")
	tick(t)
	failCI(t, r, w)
	got, code, out := sendBack(t, r.ID, "--note", "The test needs a fixed clock.")
	if code != 0 || got.State != store.RunRunning || got.Tries != 1 || got.MaxTries != 2 {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestRunSendBackKeepsTheTriesUnderTheLimit(t *testing.T) {
	s, r, _ := readyRun(t)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.State, r.Tries, r.MaxTries = store.RunStopped, store.MaxTriesLimit, store.MaxTriesLimit
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	got, code, out := sendBack(t, r.ID, "--note", "The test needs a fixed clock.")
	if code != 0 || got.State != store.RunRunning || got.MaxTries != store.MaxTriesLimit {
		t.Fatalf("exit %d: %s", code, out)
	}
}

// TAS-220: a run that is Shipping goes back too, for example when its PR
// conflicts with main. The resume is as for a Ready run, and the next tick
// leaves the run to its session.
func TestRunSendBackResumesAShippingRun(t *testing.T) {
	s, r, _ := shipRun(t, "3")
	tick(t) // the PR is open, and CI has not passed yet
	if got, _ := s.GetRun(r.ID); got.State != store.RunShipping {
		t.Fatalf("not shipping: %+v", got)
	}
	got, code, out := sendBack(t, r.ID, "--note", "Merge main into the branch.")
	if code != 0 || got.State != store.RunRunning || got.Tries != r.Tries || got.Note != "Sent back with 1 note" {
		t.Fatalf("exit %d: %s", code, out)
	}
	if prompt := lastPrompt(t); !strings.Contains(prompt, "- Merge main into the branch.") || !strings.Contains(prompt, "#1") {
		t.Fatalf("prompt %s", prompt)
	}
	tick(t)
	if after, _ := s.GetRun(r.ID); after.State != store.RunRunning || after.Note != got.Note {
		t.Fatalf("the tick changed the run that went back: %+v", after)
	}
}

func TestRunSendBackRefusesARunThatIsNotWaitingForYou(t *testing.T) {
	s, r, _ := shipRun(t, "3")
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.State = store.RunRunning; return nil }); err != nil {
		t.Fatal(err)
	}
	if _, code, out := sendBack(t, r.ID, "--note", "Hi."); code != ExitInvalid || !strings.Contains(out, "Ready to land, Shipping, or Stopped") {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestRunSendBackNeedsANote(t *testing.T) {
	_, r, _ := readyRun(t)
	if _, code, out := sendBack(t, r.ID); code != ExitInvalid || !strings.Contains(out, "--note") {
		t.Fatalf("exit %d: %s", code, out)
	}
	if _, code, out := sendBack(t, r.ID, "--note", "  "); code != ExitInvalid {
		t.Fatalf("an empty note: exit %d: %s", code, out)
	}
}
