package cli

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Run limits, the queue, turns, and usage.

func setLimits(t *testing.T, args ...string) store.RunLimits {
	t.Helper()
	out, _, err := lrRun(t, "", append([]string{"run", "limits", "--json"}, args...)...)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Limits store.RunLimits `json:"limits"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Limits
}

// startRun starts a run of the plot alpha, and returns it.
func startRun(t *testing.T, title string, args ...string) store.Run {
	t.Helper()
	out, _, err := lrRun(t, "", append([]string{"run", "start", "alpha", "--title", title, "--json"}, args...)...)
	if err != nil {
		t.Fatal(err)
	}
	var got runStartOut
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Run
}

// bgStarts are the claude --bg calls that started a new session, by the
// name of the session.
func bgStarts(t *testing.T) []string {
	t.Helper()
	var names []string
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "--bg") && !slices.Contains(c, "--resume") {
			names = append(names, argAfter(c, "--name"))
		}
	}
	return names
}

func TestRunLimitsShowsAndSetsTheLimits(t *testing.T) {
	runCLI(t)
	if got := setLimits(t); got != (store.RunLimits{AtATime: 3, MaxTurns: 40, HoldAt: 80}) {
		t.Fatalf("defaults %+v", got)
	}
	// A flag sets its limit and leaves the others.
	if got := setLimits(t, "--max-turns", "0"); got != (store.RunLimits{AtATime: 3, MaxTurns: 0, HoldAt: 80}) {
		t.Fatalf("max turns %+v", got)
	}
	if got := setLimits(t, "--at-a-time", "5", "--hold-at", "0"); got != (store.RunLimits{AtATime: 5, MaxTurns: 0, HoldAt: 0}) {
		t.Fatalf("at a time %+v", got)
	}
	for _, bad := range [][]string{{"--at-a-time", "0"}, {"--at-a-time", "21"}, {"--max-turns", "-1"}, {"--hold-at", "101"}} {
		if _, _, err := lrRun(t, "", append([]string{"run", "limits"}, bad...)...); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%v: %v", bad, err)
		}
	}
}

func TestRunStartWaitsForASlotAndATickStartsIt(t *testing.T) {
	s, _ := runCLI(t)
	setLimits(t, "--at-a-time", "1")
	first := startRun(t, "Say hi")
	second := startRun(t, "Say bye", "--model", "opus", "--effort", "high")
	if first.State != store.RunRunning || second.State != store.RunQueued || second.Note != "Waits for a slot: 1 of 1 runs are running" {
		t.Fatalf("first %+v\nsecond %+v", first, second)
	}
	if got := bgStarts(t); len(got) != 1 {
		t.Fatalf("a queued run started a session: %q", got)
	}
	// A tick with no free slot changes nothing.
	if got := tick(t); len(got.Runs) != 0 {
		t.Fatalf("tick moved %+v", got.Runs)
	}
	if got, _ := s.GetRun(second.ID); !got.UpdatedAt.Equal(second.UpdatedAt) {
		t.Fatal("a tick with no free slot wrote the run")
	}
	// The first run leaves its slot, and the tick starts the second run with
	// its model and effort.
	if _, _, err := lrRun(t, "", "run", "stop", first.ID); err != nil {
		t.Fatal(err)
	}
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].ID != second.ID || got.Runs[0].State != store.RunRunning || got.Runs[0].Note != "" {
		t.Fatalf("tick %+v", got)
	}
	inv := testutil.FakeClaudeInvocation(t)
	if argAfter(inv.Args, "--name") != "loam-run-"+second.ID || argAfter(inv.Args, "--model") != "opus" || argAfter(inv.Args, "--effort") != "high" {
		t.Fatalf("args %q", inv.Args)
	}
}

func TestRunStopCancelsAQueuedRunWithNoSession(t *testing.T) {
	runCLI(t)
	setLimits(t, "--at-a-time", "1")
	startRun(t, "Say hi")
	queued := startRun(t, "Say bye")
	out, _, err := lrRun(t, "", "run", "stop", queued.ID, "--json")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, `"state": "cancelled"`) {
		t.Fatalf("stop %s", out)
	}
	for _, c := range testutil.FakeClaudeCalls(t) {
		if len(c) > 0 && c[0] == "stop" {
			t.Fatalf("claude stop for a run with no session: %q", c)
		}
	}
}

func TestRunStartIsHeldByTheWeeksUsageUntilAProbeSaysOtherwise(t *testing.T) {
	s, _ := runCLI(t)
	// Loam read the usage an hour ago: 82% of the week.
	read := time.Now().Add(-time.Hour)
	if _, err := s.RecordUsage(store.Usage{SevenDay: &store.UsageWindow{Utilization: 0.82, ResetsAt: read.Add(48 * time.Hour)}}, read); err != nil {
		t.Fatal(err)
	}
	r := startRun(t, "Say hi")
	if r.State != store.RunQueued || r.Note != "Held: the week's usage is at 82%, over the 80% limit" {
		t.Fatalf("%+v", r)
	}
	// The usage is older than 30 minutes, so the tick probes it. Claude Code
	// says 41%, and the run starts.
	testutil.FakeClaudePrint(t, `{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.41,"resetsAt":`+
		jsonInt(read.Add(48*time.Hour).Unix())+`}}}}
{"type":"result","subtype":"success","is_error":false,"result":"ok"}
`)
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].State != store.RunRunning || len(got.Warnings) != 0 {
		t.Fatalf("tick %+v", got)
	}
	var probe []string
	for _, c := range testutil.FakeClaudeCalls(t) {
		if slices.Contains(c, "-p") {
			probe = c
		}
	}
	want := []string{"-p", "Reply with ok", "--model", "haiku", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--tools", ""}
	if !slices.Equal(probe, want) {
		t.Fatalf("probe %q", probe)
	}
	if u, _ := s.GetUsage(); u.SevenDay.Utilization != 0.41 || u.ReadAt.Before(read.Add(time.Minute)) {
		t.Fatalf("usage %+v", u)
	}
}

// A probe that fails does not run again on the next tick: Loam waits 30
// minutes after each probe that it tries.
func TestRunTickTriesOneUsageProbeIn30Minutes(t *testing.T) {
	s, _ := runCLI(t)
	setLimits(t, "--at-a-time", "1")
	first := startRun(t, "Say hi")
	read := time.Now().Add(-time.Hour)
	if _, err := s.RecordUsage(store.Usage{SevenDay: &store.UsageWindow{Utilization: 0.82, ResetsAt: read.Add(48 * time.Hour)}}, read); err != nil {
		t.Fatal(err)
	}
	queued := startRun(t, "Say bye")
	if queued.State != store.RunQueued {
		t.Fatalf("%+v", queued)
	}
	if _, _, err := lrRun(t, "", "run", "stop", first.ID); err != nil {
		t.Fatal(err)
	}
	probes := func() int {
		n := 0
		for _, c := range printCalls(t) {
			if slices.Contains(c, "Reply with ok") {
				n++
			}
		}
		return n
	}
	before := probes()
	// Claude Code reports no usage, so the probe fails.
	testutil.FakeClaudePrint(t, `{"type":"result","subtype":"success","is_error":false,"result":"ok"}`)
	got := tick(t)
	if probes() != before+1 || len(got.Warnings) != 1 || !strings.Contains(got.Warnings[0], "reported no usage") {
		t.Fatalf("first tick: %d probes, %+v", probes()-before, got)
	}
	got = tick(t)
	if probes() != before+1 || len(got.Warnings) != 0 || len(got.Runs) != 0 {
		t.Fatalf("second tick: %d probes, %+v", probes()-before, got)
	}
	if r, _ := s.GetRun(queued.ID); r.State != store.RunQueued {
		t.Fatalf("%+v", r)
	}
}

func jsonInt(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func TestUsagePrintsTheLastReportAndRefreshProbes(t *testing.T) {
	runCLI(t)
	out, _, err := lrRun(t, "", "usage", "--json")
	if err != nil || !strings.Contains(out, `"five_hour": null`) || !strings.Contains(out, `"read_at": null`) {
		t.Fatalf("%v: %s", err, out)
	}
	testutil.FakeClaudePrint(t, rateLimitStream)
	out, _, err = lrRun(t, "", "usage", "--refresh", "--json")
	var got struct {
		Usage store.Usage `json:"usage"`
	}
	if err != nil || json.Unmarshal([]byte(out), &got) != nil || got.Usage.FiveHour.Utilization != 0.18 || got.Usage.ReadAt == nil {
		t.Fatalf("%v: %s", err, out)
	}
	// A probe that reports no usage fails.
	testutil.FakeClaudePrint(t, `{"type":"result","subtype":"success","is_error":false,"result":"ok"}`)
	if _, _, err := lrRun(t, "", "usage", "--refresh"); err == nil || !strings.Contains(err.Error(), "reported no usage") {
		t.Fatalf("err %v", err)
	}
}

// rateLimitStream is the stream-json output of claude -p with the rate limit
// event of Claude Code 2.1.312.
const rateLimitStream = `{"type":"system","subtype":"init"}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793187600,"rateLimitType":"five_hour","overageStatus":"rejected","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.18,"resetsAt":1793187600,"status":"allowed"},"seven_day":{"utilization":0.18,"resetsAt":1793660400,"status":"allowed"}}}}
{"type":"result","subtype":"success","is_error":false,"result":"ok"}
`

func TestRunGateStopsTheRunAtTheTurnLimit(t *testing.T) {
	s, r := gateRun(t, "8")
	setLimits(t, "--max-turns", "2")
	if code, _ := stopHook(t, r, "Stop"); code != 2 {
		t.Fatalf("turn 1: %d", code)
	}
	// The second turn fails the checks too, and it is the last turn: the
	// session stops, and no try counts.
	if code, _ := stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("turn 2: %d", code)
	}
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunStopped || got.Turns != 2 || got.Tries != 1 || got.Note != "Stopped after 2 turns, the limit for each run" {
		t.Fatalf("%+v", got)
	}
	// A Stop of a run that is not running counts its turn too.
	stopHook(t, r, "Stop")
	if got, _ := s.GetRun(r.ID); got.Turns != 3 || got.State != store.RunStopped {
		t.Fatalf("%+v", got)
	}
}

func TestRunSendBackWaitsForASlotWithYourNotes(t *testing.T) {
	s, r, _ := readyRun(t)
	setLimits(t, "--at-a-time", "1")
	other := startRun(t, "Say bye")
	got, code, out := sendBack(t, r.ID, "--note", "Add a test.")
	if code != 0 || got.State != store.RunQueued || got.Note != "Waits for a slot: 1 of 1 runs are running" {
		t.Fatalf("exit %d: %s", code, out)
	}
	if e := events(t, s, r.ID, "note"); !slices.Equal(e, []string{"Add a test."}) {
		t.Fatalf("note events %q", e)
	}
	if _, _, err := lrRun(t, "", "run", "stop", other.ID); err != nil {
		t.Fatal(err)
	}
	tick(t)
	if got, _ := s.GetRun(r.ID); got.State != store.RunRunning {
		t.Fatalf("after the tick: %+v", got)
	}
	if prompt := lastPrompt(t); !strings.Contains(prompt, "- Add a test.") {
		t.Fatalf("prompt %s", prompt)
	}
}

func TestRunTickQueuesACIFailureWhenNoSlotIsFree(t *testing.T) {
	s, r, w := shipRun(t, "3")
	tick(t)
	setLimits(t, "--at-a-time", "1")
	other := startRun(t, "Say bye")
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "FAILURE"))
	tick(t)
	got, _ := s.GetRun(r.ID)
	if got.State != store.RunQueued || got.Tries != 1 || got.Note != "Waits for a slot: 1 of 1 runs are running" {
		t.Fatalf("%+v", got)
	}
	if e := events(t, s, r.ID, "try"); !slices.Equal(e, []string{"CI failed on #1: ci / test"}) {
		t.Fatalf("try events %q", e)
	}
	if _, _, err := lrRun(t, "", "run", "stop", other.ID); err != nil {
		t.Fatal(err)
	}
	tick(t)
	if got, _ := s.GetRun(r.ID); got.State != store.RunRunning {
		t.Fatalf("after the tick: %+v", got)
	}
	if prompt := lastPrompt(t); !strings.Contains(prompt, "--- FAIL: TestDrag") {
		t.Fatalf("prompt %s", prompt)
	}
}

// A Shape draft records the usage that Claude Code reports in its stream,
// and an approve with no free slot waits in Queued.
func TestRunShapeRecordsTheUsageAndApproveWaitsForASlot(t *testing.T) {
	s, _, _ := shapeCLI(t)
	testutil.FakeClaudePrint(t, rateLimitStream+shapeDraft)
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if u, err := s.GetUsage(); err != nil || u.SevenDay == nil || u.SevenDay.Utilization != 0.18 {
		t.Fatalf("usage %+v %v", u, err)
	}
	setLimits(t, "--at-a-time", "1")
	startRun(t, "Say hi")
	got := shapeRun(t, "approve", r.ID)
	if got.State != store.RunQueued || got.WorktreeID == "" || got.Note != "Waits for a slot: 1 of 1 runs are running" {
		t.Fatalf("%+v", got)
	}
	if starts := bgStarts(t); slices.Contains(starts, "loam-run-"+r.ID) {
		t.Fatalf("a queued run started a session: %q", starts)
	}
}
