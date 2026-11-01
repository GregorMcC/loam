package cli

import (
	"encoding/json"
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

func addRecurring(t *testing.T, args ...string) store.Recurring {
	t.Helper()
	out, errOut, err := lrRun(t, "", append([]string{"recurring", "add", "alpha"}, append(args, "--json")...)...)
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var got struct {
		Recurring store.Recurring `json:"recurring"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.Recurring
}

// tickAt runs loam tick at the time.
func tickAt(t *testing.T, at time.Time) tickResult {
	t.Helper()
	out, errOut, err := lrRun(t, "", "tick", "--now", at.Format(time.RFC3339), "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var got tickResult
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got
}

func recurringRuns(t *testing.T, s *store.Store, id string) []store.Run {
	t.Helper()
	runs, err := s.ListRuns("")
	if err != nil {
		t.Fatal(err)
	}
	var out []store.Run
	for _, r := range runs {
		if r.Source != nil && r.Source.Kind == store.SourceRecurring && r.Source.Key == id {
			out = append(out, r)
		}
	}
	return out
}

func TestRecurringAddListAndRemove(t *testing.T) {
	runCLI(t)
	r := addRecurring(t, "--title", "Bump Go dependencies", "--prompt", "Bump the Go modules that have updates.",
		"--kind", "chore", "--days", "weekdays", "--at", "02:00", "--precheck", "true", "--check", "Go tests=go test ./...")
	if !slices.Equal(r.Days, []string{"mon", "tue", "wed", "thu", "fri"}) || r.At != "02:00" || r.Kind != store.RecurringChore ||
		r.IfAsleep != store.AsleepRunOnce || len(r.DoneWhen) != 1 || !r.NextAt.After(time.Now()) {
		t.Fatalf("%+v", r)
	}
	if _, _, err := lrRun(t, "", "recurring", "add", "alpha", "--title", "T", "--prompt", "P", "--kind", "chore",
		"--days", "someday", "--at", "02:00"); err == nil || !strings.Contains(err.Error(), "not a day") {
		t.Fatalf("a bad day passed: %v", err)
	}
	out, _, err := lrRun(t, "", "recurring", "list", "alpha")
	if err != nil || !strings.Contains(out, "Bump Go dependencies") || !strings.Contains(out, "mon,tue,wed,thu,fri at 02:00") {
		t.Fatalf("%v %s", err, out)
	}
	if _, _, err := lrRun(t, "", "recurring", "rm", r.ID); err != nil {
		t.Fatal(err)
	}
	if out, _, _ := lrRun(t, "", "recurring", "list", "--json"); !strings.Contains(out, `"recurring": []`) {
		t.Fatalf("still listed: %s", out)
	}
}

// A chore whose precheck finds no work is Skipped, and a quiet week keeps one
// Skipped run. When the precheck finds work, the run starts with what it
// printed. The next time waits while that run has not ended.
func TestTickSkipsUntilThePrecheckFindsWorkThenStartsTheChore(t *testing.T) {
	s, _, repo := wtCLI(t)
	testutil.FakeClaude(t)
	trustFolder(t, repo)
	r := addRecurring(t, "--title", "Bump Go dependencies", "--prompt", "Bump the Go modules that have updates.",
		"--kind", "chore", "--days", "daily", "--at", "02:00", "--precheck", "cat updates.txt")

	day := r.NextAt.Add(time.Minute)
	got := tickAt(t, day)
	if len(got.Recurring) != 1 || got.Recurring[0].Run == nil || got.Recurring[0].Run.State != store.RunSkipped ||
		!strings.Contains(got.Recurring[0].Note, "the precheck found no work") {
		t.Fatalf("%+v", got.Recurring)
	}
	if !got.Recurring[0].Recurring.NextAt.Equal(r.NextAt.AddDate(0, 0, 1)) {
		t.Fatalf("next %v", got.Recurring[0].Recurring.NextAt)
	}
	// A second tick at the same time finds nothing due.
	if again := tickAt(t, day); len(again.Recurring) != 0 {
		t.Fatalf("ran twice: %+v", again.Recurring)
	}
	tickAt(t, day.AddDate(0, 0, 1))
	if runs := recurringRuns(t, s, r.ID); len(runs) != 1 || runs[0].State != store.RunSkipped {
		t.Fatalf("a quiet week made %d runs: %+v", len(runs), runs)
	}
	if calls := testutil.FakeClaudeCalls(t); len(calls) != 0 {
		t.Fatalf("a skip called claude: %q", calls)
	}

	if err := os.WriteFile(filepath.Join(repo, "updates.txt"), []byte("golang.org/x/net v0.30.0 [v0.31.0]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got = tickAt(t, day.AddDate(0, 0, 2))
	started := got.Recurring[0].Run
	if started == nil || started.State.Ended() || started.WorktreeID == "" || started.Source.Key != r.ID {
		t.Fatalf("%+v %q", started, got.Recurring[0].Note)
	}
	if !strings.Contains(started.Goal, "Bump the Go modules") || !strings.Contains(started.Goal, "golang.org/x/net v0.30.0 [v0.31.0]") {
		t.Fatalf("goal %q", started.Goal)
	}
	got = tickAt(t, day.AddDate(0, 0, 3))
	if got.Recurring[0].Run != nil || !strings.Contains(got.Recurring[0].Note, "the last run, "+started.ID) {
		t.Fatalf("a run stacked: %+v", got.Recurring[0])
	}
	if runs := recurringRuns(t, s, r.ID); len(runs) != 2 {
		t.Fatalf("%d runs", len(runs))
	}
}

func TestTickRunsTimesTheMacSleptThroughOnceOrSkipsThem(t *testing.T) {
	s, _ := runCLI(t)
	testutil.FakeClaudePrint(t, shapeDraft)
	once := addRecurring(t, "--title", "Shape new issues", "--prompt", "Shape a run for each new bug.",
		"--kind", "shape", "--days", "daily", "--at", "06:30")
	skip := addRecurring(t, "--title", "Find one flaky test", "--prompt", "Find one flaky driver test.",
		"--kind", "chore", "--days", "daily", "--at", "06:30", "--if-asleep", "skip")

	// The Mac slept for three days.
	got := tickAt(t, once.NextAt.AddDate(0, 0, 3).Add(time.Hour))
	if len(got.Recurring) != 2 {
		t.Fatalf("%+v", got.Recurring)
	}
	for _, res := range got.Recurring {
		if !res.Recurring.NextAt.Equal(once.NextAt.AddDate(0, 0, 4)) {
			t.Errorf("%s: next %v", res.Recurring.Title, res.Recurring.NextAt)
		}
	}
	if runs := recurringRuns(t, s, once.ID); len(runs) != 1 || runs[0].State != store.RunShaping || runs[0].Shape.DraftedAt == nil {
		t.Fatalf("once: %+v", runs)
	}
	if runs := recurringRuns(t, s, skip.ID); len(runs) != 1 || runs[0].State != store.RunSkipped ||
		!strings.Contains(runs[0].Note, "the Mac was asleep") {
		t.Fatalf("skip: %+v", runs)
	}
}

// A Shape run gives Claude its prompt as the brief, and Run now keeps the
// next time.
func TestRecurringRunNowShapesARunFromThePrompt(t *testing.T) {
	runCLI(t)
	testutil.FakeClaudePrint(t, shapeDraft)
	r := addRecurring(t, "--title", "Shape new issues", "--prompt", "Shape a run for each new bug in the tracker.",
		"--kind", "shape", "--days", "mon", "--at", "06:30", "--precheck", "echo 2 new bugs")
	out, errOut, err := lrRun(t, "", "recurring", "run", r.ID, "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res run.RecurringResult
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	if res.Run == nil || res.Run.State != store.RunShaping || res.Note != "Claude drafted a run for your approval" ||
		!res.Recurring.NextAt.Equal(r.NextAt) || res.Recurring.LastRunID != res.Run.ID {
		t.Fatalf("%+v", res)
	}
	prompt := argAfter(testutil.FakeClaudeInvocation(t).Args, "-p")
	for _, want := range []string{"Shape a run for each new bug in the tracker.", "2 new bugs"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "Issue: ") {
		t.Errorf("the prompt names an issue:\n%s", prompt)
	}
}

func TestTickInstallLoadsALaunchdAgent(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := t.TempDir()
	log := filepath.Join(dir, "launchctl.log")
	fake := filepath.Join(dir, "launchctl")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\necho \"$@\" >> '"+log+"'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_LAUNCHCTL", fake)

	var st tickStatus
	out, errOut, err := lrRun(t, "", "tick", "install", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil || !st.Installed || st.Interval != 300 {
		t.Fatalf("%v %s", err, out)
	}
	b, err := os.ReadFile(filepath.Join(home, "Library/LaunchAgents/dev.loam.tick.plist"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"<string>tick</string>", "<key>LOAM_HOME</key><string>" + os.Getenv("LOAM_HOME"), "<integer>300</integer>"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("plist misses %q:\n%s", want, b)
		}
	}
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "bootstrap gui/") || !strings.Contains(string(calls), "dev.loam.tick.plist") {
		t.Fatalf("launchctl: %s", calls)
	}

	tickAt(t, time.Now())
	out, _, _ = lrRun(t, "", "tick", "status", "--json")
	if err := json.Unmarshal([]byte(out), &st); err != nil || st.LastTick == nil || st.LastTick.Error != "" {
		t.Fatalf("%v %s", err, out)
	}
	if _, _, err := lrRun(t, "", "tick", "uninstall"); err != nil {
		t.Fatal(err)
	}
	out, _, _ = lrRun(t, "", "tick", "status", "--json")
	if err := json.Unmarshal([]byte(out), &st); err != nil || st.Installed {
		t.Fatalf("%v %s", err, out)
	}
}

// A check of an earlier gate can write the commondir file of the git folder.
// Loam runs the precheck outside the sandbox, so it refuses before the command
// can start git, which would follow the file.
func TestTickDoesNotRunThePrecheckWhenACommondirFileNamesAnotherFolder(t *testing.T) {
	s, _, repo := wtCLI(t)
	marker := filepath.Join(t.TempDir(), "precheck-ran")
	r := addRecurring(t, "--title", "Bump", "--prompt", "Bump.",
		"--kind", "chore", "--days", "daily", "--at", "02:00", "--precheck", "touch '"+marker+"'")
	if err := os.WriteFile(filepath.Join(repo, ".git", "commondir"), []byte(t.TempDir()+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := tickAt(t, r.NextAt.Add(time.Minute))
	if _, err := os.Stat(marker); err == nil {
		t.Error("the precheck ran with a commondir file that names another folder")
	}
	if len(got.Recurring) != 1 || !strings.Contains(got.Recurring[0].Note, "the precheck did not run") ||
		!strings.Contains(got.Recurring[0].Note, "commondir") {
		t.Fatalf("%+v", got.Recurring)
	}
	if runs := recurringRuns(t, s, r.ID); len(runs) != 1 || runs[0].State != store.RunSkipped {
		t.Fatalf("%+v", runs)
	}
}
