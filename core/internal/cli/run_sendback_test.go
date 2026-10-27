package cli

import (
	"encoding/json"
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
	if n < 2 || !slices.Equal(calls[n-2], []string{"stop", shipSession[:8]}) || len(calls[n-1]) != 4 ||
		!slices.Equal(calls[n-1][:3], []string{"--bg", "--resume", shipSession}) {
		t.Fatalf("claude calls %q", calls)
	}
	return calls[n-1][3]
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
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "FAILURE"))
	tick(t)
	got, code, out := sendBack(t, r.ID, "--note", "The test needs a fixed clock.")
	if code != 0 || got.State != store.RunRunning || got.Tries != 1 || got.MaxTries != 2 {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestRunSendBackRefusesARunThatIsNotWaitingForYou(t *testing.T) {
	_, r, _ := shipRun(t, "3")
	if _, code, out := sendBack(t, r.ID, "--note", "Hi."); code != ExitInvalid || !strings.Contains(out, "Ready to land or Stopped") {
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
