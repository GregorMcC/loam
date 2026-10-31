package run

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// gateTimes sets the check timeout, the gate budget, and the poll of the
// gate lock for one test.
func gateTimes(t *testing.T, check, budget time.Duration) {
	t.Helper()
	oldCheck, oldBudget, oldPoll, oldReserve := checkTimeout, gateBudget, gateLockPoll, committedReserve
	checkTimeout, gateBudget, gateLockPoll, committedReserve = check, budget, 10*time.Millisecond, 50*time.Millisecond
	t.Cleanup(func() {
		checkTimeout, gateBudget, gateLockPoll, committedReserve = oldCheck, oldBudget, oldPoll, oldReserve
	})
}

// lockedGateRun returns a store and a running run in a clean repo, with one
// Done when check.
func lockedGateRun(t *testing.T, check store.Check) (*store.Store, store.Run) {
	t.Helper()
	testutil.GitEnv(t)
	testutil.FakeSandbox(t)
	repo, _ := testutil.GitRepo(t)
	s, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	res, err := s.CreatePlot(store.PlotInput{Name: "Gate", Repos: []store.RepoInput{{Path: repo}}}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.AddRun(store.Run{PlotID: res.Plot.ID, Folder: repo, Title: "Gate", Goal: "Pass the gate",
		DoneWhen: []store.Check{check}, State: store.RunRunning, MaxTries: 3})
	if err != nil {
		t.Fatal(err)
	}
	return s, r
}

// holdGateLock takes the gate lock of the home of s, as the gate of another
// run does, and returns the function that frees it.
func holdGateLock(t *testing.T, s *store.Store) func() {
	t.Helper()
	unlock, ok, err := lockFile(filepath.Join(s.Home(), gateLockFile))
	if err != nil || !ok {
		t.Fatalf("take the gate lock: ok %v, err %v", ok, err)
	}
	t.Cleanup(unlock)
	return unlock
}

// stop runs the Stop gate of the run and returns its exit code and reason.
func stop(t *testing.T, s *store.Store, r store.Run) (int, string) {
	t.Helper()
	var errOut bytes.Buffer
	code := stopped(s, r.ID, &errOut, func(format string, a ...any) { t.Logf(format, a...) })
	return code, errOut.String()
}

// gateEvents returns the details of the events of kind of the run.
func gateEvents(t *testing.T, s *store.Store, r store.Run, kind string) []string {
	t.Helper()
	events, err := s.RunEvents(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range events {
		if e.Kind == kind {
			out = append(out, e.Detail)
		}
	}
	return out
}

// TAS-213: a gate whose lock another gate holds records that it waits, and
// runs its checks when the lock is free. The wait does not count toward the
// check timeout: the gate waits longer than that, and the check passes.
func TestGateWaitsForTheGateOfAnotherRun(t *testing.T) {
	gateTimes(t, 300*time.Millisecond, time.Minute)
	s, r := lockedGateRun(t, store.Check{Name: "Hello", Command: "true"})
	unlock := holdGateLock(t, s)

	type result struct {
		code   int
		reason string
	}
	done := make(chan result, 1)
	go func() {
		var errOut bytes.Buffer
		code := stopped(s, r.ID, &errOut, func(string, ...any) {})
		done <- result{code, errOut.String()}
	}()
	deadline := time.Now().Add(10 * time.Second)
	for len(gateEvents(t, s, r, "gate")) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the gate recorded no wait")
		}
		time.Sleep(10 * time.Millisecond)
	}
	select {
	case res := <-done:
		t.Fatalf("the gate did not wait for the lock: %+v", res)
	case <-time.After(2 * checkTimeout):
	}
	unlock()
	res := <-done
	if res.code != 0 {
		t.Fatalf("code %d, reason:\n%s", res.code, res.reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunReady || got.Tries != 0 || got.GateTimeouts != 0 {
		t.Fatalf("after the gate: %+v", got)
	}
	waits := gateEvents(t, s, r, "gate")
	if len(waits) != 2 || waits[0] != "Waits for the gate of another run to end its checks" ||
		!strings.HasPrefix(waits[1], "Waited ") || !strings.HasSuffix(waits[1], " for the gate of another run") {
		t.Fatalf("gate events %q", waits)
	}
	if checks := gateEvents(t, s, r, "check"); len(checks) != 2 || !strings.HasPrefix(checks[0], "Hello passed") {
		t.Fatalf("check events %q", checks)
	}
}

// TAS-213: when the wait for the lock leaves the budget no time for the
// checks, the gate runs none and counts no try. The session ends its turn
// again, and Loam runs the gate again.
func TestGateThatWaitsOutTheBudgetCountsNoTry(t *testing.T) {
	gateTimes(t, 300*time.Millisecond, 500*time.Millisecond)
	marker := filepath.Join(t.TempDir(), "ran")
	s, r := lockedGateRun(t, store.Check{Name: "Hello", Command: "touch " + shellQuote(marker)})
	holdGateLock(t, s)

	code, reason := stop(t, s, r)
	if code != 2 || !strings.Contains(reason, "for the gate of another run, which left no time for the checks") ||
		!strings.Contains(reason, "no try counts") || !strings.Contains(reason, "End your turn now and change nothing") {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("the check ran without the gate lock")
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunRunning || got.Tries != 0 || got.GateTimeouts != 0 ||
		!strings.Contains(got.Note, "left no time for the checks. No try counted") {
		t.Fatalf("after the first gate: %+v", got)
	}
	if checks := gateEvents(t, s, r, "check"); len(checks) != 0 {
		t.Fatalf("check events %q", checks)
	}
	if waits := gateEvents(t, s, r, "gate"); len(waits) != 2 || !strings.HasSuffix(waits[1], "which left no time for the checks") {
		t.Fatalf("gate events %q", waits)
	}

	// The lock gives no turn order, so a run can wait out again. That never
	// stops it.
	for i := 2; i <= 3; i++ {
		if code, reason = stop(t, s, r); code != 2 || !strings.Contains(reason, "left no time for the checks") {
			t.Fatalf("gate %d: code %d, reason:\n%s", i, code, reason)
		}
		if got, _ = s.GetRun(r.ID); got.State != store.RunRunning || got.Tries != 0 || got.GateTimeouts != 0 {
			t.Fatalf("after gate %d: %+v", i, got)
		}
	}
}

// TAS-213: a wait-out between two check timeouts leaves their count as it
// is: the second check timeout still stops the run.
func TestWaitOutLeavesTheTimeoutCount(t *testing.T) {
	gateTimes(t, 200*time.Millisecond, time.Minute)
	s, r := lockedGateRun(t, store.Check{Name: "Slow", Command: "exec sleep 5"})
	if code, _ := stop(t, s, r); code != 2 {
		t.Fatalf("first timeout: code %d", code)
	}
	unlock := holdGateLock(t, s)
	gateBudget = 300 * time.Millisecond // a wait of 50ms at most
	if code, reason := stop(t, s, r); code != 2 || !strings.Contains(reason, "left no time for the checks") {
		t.Fatalf("wait-out: code %d, reason:\n%s", code, reason)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunRunning || got.GateTimeouts != 1 {
		t.Fatalf("after the wait-out: %+v", got)
	}
	unlock()
	gateBudget = time.Minute
	if code, _ := stop(t, s, r); code != 0 {
		t.Fatalf("second timeout: code %d", code)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunStopped || got.Note != "Slow did not end in 200ms, 2 gates in a row. No try counted" {
		t.Fatalf("after the second timeout: %+v", got)
	}
}

// TAS-213: a check that times out counts no try. The first timeout asks the
// session to end its turn with no change. The second timeout in a row stops
// the run, with a note that names the check and the timeout. A gate between
// them that fails for another reason counts a try, and the timeouts start
// again from 0.
func TestCheckTimeoutCountsNoTry(t *testing.T) {
	gateTimes(t, 200*time.Millisecond, time.Minute)
	mode := filepath.Join(t.TempDir(), "mode")
	setMode := func(m string) {
		t.Helper()
		if err := os.WriteFile(mode, []byte(m), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// The check sleeps in mode slow, fails in mode fail, and passes in mode
	// pass. The mode file is outside the repo, so Work committed passes.
	command := `m=$(cat ` + shellQuote(mode) + `); [ "$m" = slow ] && exec sleep 5; [ "$m" = pass ]`
	s, r := lockedGateRun(t, store.Check{Name: "Slow", Command: command})

	setMode("slow")
	code, reason := stop(t, s, r)
	const why = "Slow did not end in 200ms"
	if code != 2 || !strings.HasPrefix(reason, "Loam gate: "+why+". ") || !strings.Contains(reason, "End your turn now and change nothing") {
		t.Fatalf("first timeout: code %d, reason:\n%s", code, reason)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunRunning || got.Tries != 0 || got.GateTimeouts != 1 ||
		got.Note != why+". No try counted, and Loam runs the checks again" {
		t.Fatalf("after the first timeout: %+v", got)
	}
	if checks := gateEvents(t, s, r, "check"); len(checks) != 2 || checks[0] != why {
		t.Fatalf("check events %q", checks)
	}

	setMode("fail")
	if code, reason = stop(t, s, r); code != 2 || !strings.Contains(reason, "try 1 of 3") {
		t.Fatalf("a failure: code %d, reason:\n%s", code, reason)
	}
	if got, _ = s.GetRun(r.ID); got.Tries != 1 || got.GateTimeouts != 0 {
		t.Fatalf("after a failure: %+v", got)
	}

	setMode("slow")
	if code, reason = stop(t, s, r); code != 2 {
		t.Fatalf("a timeout after a failure: code %d, reason:\n%s", code, reason)
	}
	if got, _ = s.GetRun(r.ID); got.State != store.RunRunning || got.Tries != 1 || got.GateTimeouts != 1 {
		t.Fatalf("after a timeout after a failure: %+v", got)
	}

	if code, reason = stop(t, s, r); code != 0 {
		t.Fatalf("second timeout in a row: code %d, reason:\n%s", code, reason)
	}
	got, _ = s.GetRun(r.ID)
	if got.State != store.RunStopped || got.Tries != 1 || got.Note != why+", 2 gates in a row. No try counted" {
		t.Fatalf("after the second timeout in a row: %+v", got)
	}
}

// TAS-213: a gate runs out of time only when each failed check ran out of
// time. A check that fails for another reason makes the try count, as the
// session can fix it.
func TestGateOutOfTimeNeedsEachFailureToBeATimeout(t *testing.T) {
	timedOut := checkResult{check: store.Check{Name: "Slow"}, exit: -1, timeout: "did not end in 10m"}
	notRun := checkResult{check: store.Check{Name: CommittedCheck}, exit: -1, timeout: "did not run, because the gate ran out of time"}
	failed := checkResult{check: store.Check{Name: "Lint"}, exit: 1}
	passed := checkResult{check: store.Check{Name: "Test"}, passed: true}
	for _, c := range []struct {
		name    string
		results []checkResult
		why     string
	}{
		{"pass", []checkResult{passed}, ""},
		{"timeout", []checkResult{passed, timedOut, notRun}, "Slow did not end in 10m"},
		{"timeout and failure", []checkResult{timedOut, failed}, ""},
		{"failure", []checkResult{failed}, ""},
	} {
		var g gateResult
		for _, res := range c.results {
			g.add(res)
		}
		if why, ok := g.outOfTime(); why != c.why || ok != (c.why != "") {
			t.Errorf("%s: %q %v, want %q", c.name, why, ok, c.why)
		}
	}
}

func TestShortDuration(t *testing.T) {
	for d, want := range map[time.Duration]string{
		10 * time.Minute:                      "10m",
		3*time.Minute + 12*time.Second:        "3m12s",
		90 * time.Minute:                      "1h30m",
		time.Hour:                             "1h",
		200 * time.Millisecond:                "200ms",
		28*time.Minute + 400*time.Millisecond: "28m",
	} {
		if got := shortDuration(d); got != want {
			t.Errorf("%s: %q, want %q", d, got, want)
		}
	}
}

// TAS-213: a send back starts the count of the gates that ran out of time
// again. After two timeouts stopped the run, its first timeout after the
// send back blocks the stop with the first note again, and does not stop it.
func TestSendBackStartsTheTimeoutsAgain(t *testing.T) {
	testutil.Home(t)
	testutil.FakeClaude(t)
	gateTimes(t, 200*time.Millisecond, time.Minute)
	s, r := lockedGateRun(t, store.Check{Name: "Slow", Command: "exec sleep 5"})
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.SessionID = "c57ef956-3136-4e86-bfde-da8facfe0523"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if code, _ := stop(t, s, r); code != 2 {
		t.Fatalf("first timeout: code %d", code)
	}
	if code, _ := stop(t, s, r); code != 0 {
		t.Fatalf("second timeout: code %d", code)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunStopped || got.GateTimeouts != 2 {
		t.Fatalf("after two timeouts: %+v", got)
	}

	got, _, err := SendBack(context.Background(), s, r.ID, []Note{{Text: "Try again."}})
	if err != nil {
		t.Fatal(err)
	}
	if got.State != store.RunRunning || got.GateTimeouts != 0 {
		t.Fatalf("after the send back: %+v", got)
	}
	code, reason := stop(t, s, r)
	if code != 2 || !strings.HasPrefix(reason, "Loam gate: Slow did not end in 200ms. ") {
		t.Fatalf("timeout after the send back: code %d, reason:\n%s", code, reason)
	}
	if got, _ = s.GetRun(r.ID); got.State != store.RunRunning || got.Tries != 0 || got.GateTimeouts != 1 {
		t.Fatalf("after the timeout after the send back: %+v", got)
	}
}

// TAS-213: the gate keeps the time that every check can take, so a run with
// two checks waits less than a run with one. A run whose checks can take more
// than the whole budget keeps the time of one check, so it still waits for
// the lock and does not block the stop at once.
func TestGateKeepsTimeForEachCheck(t *testing.T) {
	cases := []struct {
		name   string
		checks int
		// The budget is 3s and a check has 1s. The checks and the 50ms of
		// Work committed need 1.05s, 2.05s, or 3.05s, more than the budget,
		// so the last case keeps 1.05s.
		minWait, maxWait time.Duration
	}{
		{"one check", 1, 1500 * time.Millisecond, 2500 * time.Millisecond},
		{"two checks", 2, 500 * time.Millisecond, 1500 * time.Millisecond},
		{"too many checks", 3, 1500 * time.Millisecond, 2500 * time.Millisecond},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gateTimes(t, time.Second, 3*time.Second)
			marker := filepath.Join(t.TempDir(), "ran")
			s, r := lockedGateRun(t, store.Check{Name: "Hello", Command: "touch " + shellQuote(marker)})
			if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
				for i := 1; i < c.checks; i++ {
					r.DoneWhen = append(r.DoneWhen, store.Check{Name: fmt.Sprintf("Also %d", i), Command: "true"})
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			unlock := holdGateLock(t, s)
			start := time.Now()
			code, reason := stop(t, s, r)
			waited := time.Since(start)
			if code != 2 || !strings.Contains(reason, "which left no time for the checks") {
				t.Fatalf("code %d, reason:\n%s", code, reason)
			}
			if waited < c.minWait || waited > c.maxWait {
				t.Fatalf("the gate waited %s, want %s to %s", waited, c.minWait, c.maxWait)
			}
			if _, err := os.Stat(marker); err == nil {
				t.Fatal("the check ran without the gate lock")
			}
			if got, _ := s.GetRun(r.ID); got.State != store.RunRunning || got.Tries != 0 || got.GateTimeouts != 0 {
				t.Fatalf("after the gate: %+v", got)
			}
			unlock()
			if code, reason = stop(t, s, r); code != 0 {
				t.Fatalf("with the lock free: code %d, reason:\n%s", code, reason)
			}
		})
	}
}

// TAS-213: a gate that waited and then ran out of the gate budget ran out of
// time because of the wait, so it does not count toward the stop. A gate that
// did not wait, or whose check ran out of its own timeout, does.
func TestWaitCausedTellsAWaitFromTheWork(t *testing.T) {
	budget := checkResult{check: store.Check{Name: "Slow"}, exit: -1, timeout: "did not end before the gate ran out of time", budget: true}
	own := checkResult{check: store.Check{Name: "Slow"}, exit: -1, timeout: "did not end in 10m"}
	for _, c := range []struct {
		name string
		g    gateResult
		want bool
	}{
		{"wait-out", gateResult{waitedOut: true, waited: time.Minute}, true},
		{"budget after a wait", gateResult{waited: time.Minute, failed: []checkResult{budget}}, true},
		{"budget with no wait", gateResult{failed: []checkResult{budget}}, false},
		{"own timeout after a wait", gateResult{waited: time.Minute, failed: []checkResult{own, budget}}, false},
		{"no timeout", gateResult{waited: time.Minute}, false},
	} {
		if got := c.g.waitCaused(); got != c.want {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

// TAS-213: Claude Code lets a session stop after 8 blocked stops in a row,
// and the run would then wait in Running with no session at work. So the
// gate blocks at most 7 stops in a row, and stops the run at the 8th. A stop
// that the gate lets end starts the count again.
func TestGateBlocksAtMostSevenStopsInARow(t *testing.T) {
	gateTimes(t, 200*time.Millisecond, 300*time.Millisecond) // a wait of 50ms at most
	s, r := lockedGateRun(t, store.Check{Name: "Hello", Command: "true"})
	unlock := holdGateLock(t, s)
	for i := 1; i <= 3; i++ {
		if code, reason := stop(t, s, r); code != 2 {
			t.Fatalf("wait-out %d: code %d, reason:\n%s", i, code, reason)
		}
	}
	if got, _ := s.GetRun(r.ID); got.BlockedStops != 3 {
		t.Fatalf("after 3 blocked stops: %+v", got)
	}
	// A gate that passes lets the session stop and starts the count again.
	// The test then puts the run back in Running by hand.
	unlock()
	gateBudget = time.Minute
	if code, reason := stop(t, s, r); code != 0 {
		t.Fatalf("passing gate: code %d, reason:\n%s", code, reason)
	}
	got, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.State = store.RunRunning; return nil })
	if err != nil || got.BlockedStops != 0 {
		t.Fatalf("after a passing gate: %+v, %v", got, err)
	}

	holdGateLock(t, s)
	gateBudget = 300 * time.Millisecond
	for i := 1; i <= maxBlockedStops; i++ {
		if code, reason := stop(t, s, r); code != 2 {
			t.Fatalf("wait-out %d: code %d, reason:\n%s", i, code, reason)
		}
	}
	if code, reason := stop(t, s, r); code != 0 {
		t.Fatalf("the 8th blocked stop: code %d, reason:\n%s", code, reason)
	}
	got, _ = s.GetRun(r.ID)
	if got.State != store.RunStopped || got.Tries != 0 || got.BlockedStops != 0 ||
		!strings.HasPrefix(got.Note, "Stopped after 7 blocked stops in a row, the most that Claude Code allows. The last gate: The gate waited ") ||
		!strings.HasSuffix(got.Note, "which left no time for the checks. No try counted") {
		t.Fatalf("after the 8th blocked stop: %+v", got)
	}
}
