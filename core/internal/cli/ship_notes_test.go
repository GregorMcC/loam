package cli

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ship notes: Claude writes them for every PR that Loam opens, and the land
// of the run uses them. Switches turn each update to Linear on or off.

// notesAnswer is the ship notes that claude -p prints for a repo with no PR
// template. nope.go is a file that the branch did not change.
const notesAnswer = `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"walkthrough": "Adds hello.txt, which greets the user.",
  "files": [{"path": "nope.go", "role": "Not changed"}, {"path": "./hello.txt", "role": "The greeting"}],
  "risk": {"level": "low", "reasons": ["One new file.", " "]},
  "where_it_stands": "The greeting is in. Next: the farewell."}}`

// linearSource gives the run the Linear issue ENG-523.
func linearSource(t *testing.T, s *store.Store, r store.Run) {
	t.Helper()
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Source = &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// withNotes gives the run ship notes, as the tick that opened its PR writes
// them.
func withNotes(t *testing.T, s *store.Store, r store.Run) store.RunNotes {
	t.Helper()
	n := store.RunNotes{
		Walkthrough:   "Adds hello.txt, which greets the user.",
		Files:         []store.NoteFile{{Path: "hello.txt", Role: "The greeting"}},
		Risk:          store.NoteRisk{Level: store.RiskLow, Reasons: []string{"One new file."}},
		WhereItStands: "The greeting is in. Next: the farewell.",
		WrittenAt:     time.Now(),
	}
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error { r.Notes = &n; return nil }); err != nil {
		t.Fatal(err)
	}
	return n
}

// linearCalls returns the requests to the fake Linear whose query holds
// the text.
func linearCalls(f *testutil.FakeLinearServer, text string) []testutil.LinearCall {
	return slices.DeleteFunc(f.Calls(), func(c testutil.LinearCall) bool { return !strings.Contains(c.Query, text) })
}

func TestRunTickWritesShipNotesWithNoTemplate(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, notesAnswer)
	if _, errOut, err := lrRun(t, "", "set", "alpha", "where-it-stands", "Nothing greets the user yet."); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	// The run has a plan that names hello.txt, and the branch also changes go.mod.
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Shape = &store.RunShape{Plan: []string{"Write hello.txt."}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	writeAndCommit(t, r.Folder, "go.mod", "module example.com/hi\n")
	tick(t)

	// With no template, the PR keeps the body that Loam makes.
	if title, body := openedPR(t); title != "Say hi" || !strings.HasPrefix(body, "Say hi\n\n## Done when\n\n") {
		t.Fatalf("title %q body %q", title, body)
	}
	got, err := s.GetRun(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	n := got.Notes
	if n == nil || got.PR == nil {
		t.Fatalf("run %+v", got)
	}
	wantFiles := []store.NoteFile{{Path: "hello.txt", Role: "The greeting"}, {Path: "go.mod", Role: "Also changed"}}
	wantReasons := []string{"One new file.", "1 changed file is not in the plan: go.mod.", "The diff changes a dependency file: go.mod."}
	if n.Walkthrough != "Adds hello.txt, which greets the user." || !slices.Equal(n.Files, wantFiles) ||
		n.Risk.Level != store.RiskLow || !slices.Equal(n.Risk.Reasons, wantReasons) ||
		n.WhereItStands != "The greeting is in. Next: the farewell." || n.WrittenAt.IsZero() {
		t.Fatalf("notes %+v", n)
	}
	calls := printCalls(t)
	if len(calls) != 1 {
		t.Fatalf("claude -p calls %q", calls)
	}
	args := calls[0]
	schema := args[slices.Index(args, "--json-schema")+1]
	if !strings.Contains(schema, "walkthrough") || strings.Contains(schema, `"title"`) {
		t.Fatalf("schema %s", schema)
	}
	prompt := args[slices.Index(args, "-p")+1]
	for _, want := range []string{"Nothing greets the user yet.", "1. Write hello.txt.", "- go.mod", "- hello.txt"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	for _, d := range events(t, s, r.ID, "ship") {
		if strings.Contains(d, "notes") || strings.Contains(d, "template") {
			t.Fatalf("event %q", d)
		}
	}
	// The run JSON always has notes.
	out, code := loam(t, "run", "status", r.ID, "--json")
	if code != 0 || !strings.Contains(out, `"where_it_stands": "The greeting is in. Next: the farewell."`) {
		t.Fatalf("exit %d: %s", code, out)
	}
}

// A PR that GitHub does not open keeps the text that Claude wrote, and the
// next tick opens the PR with it and calls no claude -p.
func TestRunTickOpensThePRWithTheSavedTextAfterAFailedCreate(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, notesAnswer)
	setGitHub(t, `{"create_refusal": "Something went wrong"}`)
	got := tick(t)
	if len(got.Warnings) != 1 || !strings.Contains(got.Warnings[0], "Something went wrong") || len(printCalls(t)) != 1 {
		t.Fatalf("first tick %+v, %d claude -p calls", got, len(printCalls(t)))
	}
	if r, _ := s.GetRun(r.ID); r.PR != nil || r.Notes != nil || r.State != store.RunShipping {
		t.Fatalf("run %+v", r)
	}
	setGitHub(t, `{}`)
	got = tick(t)
	if len(got.Runs) != 1 || got.Runs[0].PR == nil || len(printCalls(t)) != 1 {
		t.Fatalf("second tick %+v, %d claude -p calls", got, len(printCalls(t)))
	}
	n := got.Runs[0].Notes
	if n == nil || n.Walkthrough != "Adds hello.txt, which greets the user." {
		t.Fatalf("notes %+v", n)
	}
	if title, _ := openedPR(t); title != "Say hi" {
		t.Fatalf("title %q", title)
	}
	if r, _ := s.GetRun(r.ID); r.PRDraft != nil {
		t.Fatalf("draft %+v", r.PRDraft)
	}
}

// Text that Loam wrote because Claude could not is not saved: after a failed
// create, the next tick asks Claude again.
func TestRunTickAsksClaudeAgainAfterAFailedCreateWithNoNotes(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, `{"type":"result","subtype":"success","is_error":false,"result":"not JSON"}`)
	setGitHub(t, `{"create_refusal": "Something went wrong"}`)
	if got := tick(t); len(got.Warnings) != 1 || len(printCalls(t)) != 1 {
		t.Fatalf("first tick %+v, %d claude -p calls", got, len(printCalls(t)))
	}
	if r, _ := s.GetRun(r.ID); r.PRDraft != nil {
		t.Fatalf("Loam saved its own text: %+v", r.PRDraft)
	}
	testutil.FakeClaudePrint(t, notesAnswer)
	setGitHub(t, `{}`)
	got := tick(t)
	if len(got.Runs) != 1 || got.Runs[0].Notes == nil || len(printCalls(t)) != 2 {
		t.Fatalf("second tick %+v, %d claude -p calls", got, len(printCalls(t)))
	}
}

func TestRunTickWithNoNotesSaysWhy(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, `{"type": "result", "subtype": "error_max_turns", "is_error": true, "result": "Claude ran out of turns"}`)
	tick(t)
	got, _ := s.GetRun(r.ID)
	if got.PR == nil || got.Notes != nil {
		t.Fatalf("run %+v", got)
	}
	if e := events(t, s, r.ID, "ship"); !slices.ContainsFunc(e, func(d string) bool {
		return strings.HasPrefix(d, "Loam wrote no ship notes: ") && strings.Contains(d, "Claude ran out of turns")
	}) {
		t.Fatalf("ship events %q", e)
	}
	out, code := loam(t, "run", "status", r.ID, "--json")
	if code != 0 || !strings.Contains(out, `"notes": null`) {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestRunLandSetsWhereItStandsFromTheNotes(t *testing.T) {
	s, r, _ := readyRun(t)
	n := withNotes(t, s, r)
	got, code, out := runLand(t, r.ID, "--where-it-stands")
	if code != 0 || got.Run.State != store.RunLanded || len(got.Warnings) != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	p, err := s.GetPlot(r.PlotID)
	if err != nil {
		t.Fatal(err)
	}
	// The text goes through the change log, as loam set does.
	if p.Where != n.WhereItStands || p.Versions[store.ItemWhere] == 0 {
		t.Fatalf("plot %+v", p)
	}
}

func TestRunLandWithWhereItStandsNeedsNotes(t *testing.T) {
	s, r, _ := readyRun(t)
	if _, code, out := runLand(t, r.ID, "--where-it-stands"); code != ExitInvalid || !strings.Contains(out, "ship notes") {
		t.Fatalf("exit %d: %s", code, out)
	}
	if got, _ := s.GetRun(r.ID); got.State != store.RunReady {
		t.Fatalf("run %+v", got)
	}
}

func TestRunLandWithNoLinearDoneLeavesTheIssue(t *testing.T) {
	s, r, _ := readyRun(t)
	f := testutil.FakeLinear(t)
	linearSource(t, s, r)
	withNotes(t, s, r)
	got, code, out := runLand(t, r.ID, "--no-linear-done")
	if code != 0 || got.Run.State != store.RunLanded {
		t.Fatalf("exit %d: %s", code, out)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"This land leaves ENG-523 where it is"}) {
		t.Fatalf("linear events %q", e)
	}
	// The walkthrough comment is off by default.
	if c := linearCalls(f, "issueUpdate"); len(c) != 0 || len(linearCalls(f, "commentCreate")) != 0 {
		t.Fatalf("calls %+v", f.Calls())
	}
}

func TestRunLandAddsTheWalkthroughAsACommentWhenThatUpdateIsOn(t *testing.T) {
	s, r, _ := readyRun(t)
	f := testutil.FakeLinear(t)
	linearSource(t, s, r)
	withNotes(t, s, r)
	if _, errOut, err := lrRun(t, "", "linear", "updates", "--walkthrough", "on"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	if _, code, out := runLand(t, r.ID); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	c := linearCalls(f, "commentCreate")
	want := "Landed in #1 by a Loam run. Adds hello.txt, which greets the user. 2 of 2 checks passed."
	if len(c) != 1 || c[0].Variables["id"] != "ENG-523" || c[0].Variables["body"] != want {
		t.Fatalf("comment calls %+v", c)
	}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, []string{"Moved ENG-523 to Done", "Added the walkthrough to ENG-523 as a comment"}) {
		t.Fatalf("linear events %q", e)
	}
}

func TestLinearUpdatesThatAreOffMakeNoCalls(t *testing.T) {
	s, r, w := shipRun(t, "3")
	f := testutil.FakeLinear(t)
	linearSource(t, s, r)
	if _, errOut, err := lrRun(t, "", "linear", "updates", "--attach-pr", "off", "--done", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	tick(t)
	setGitHub(t, ciState(w.Branch, testutil.Git(t, r.Folder, "rev-parse", "HEAD"), "SUCCESS"))
	tick(t)
	if _, code, out := runLand(t, r.ID); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	if len(f.Calls()) != 0 {
		t.Fatalf("calls %+v", f.Calls())
	}
	want := []string{"Loam did not attach #1 to ENG-523: that update to Linear is off",
		"Loam did not move ENG-523 to Done: that update to Linear is off"}
	if e := events(t, s, r.ID, "linear"); !slices.Equal(e, want) {
		t.Fatalf("linear events %q", e)
	}
}

func TestRunStartWithInProgressOffLeavesTheIssue(t *testing.T) {
	s, _ := runCLI(t)
	f := testutil.FakeLinear(t)
	if _, errOut, err := lrRun(t, "", "linear", "updates", "--in-progress", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Drag a link",
		"--link", "https://linear.app/acme/issue/ENG-523/plot-panel-drag", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res runStartOut
	json.Unmarshal([]byte(out), &res)
	if len(linearCalls(f, "issueUpdate")) != 0 {
		t.Fatalf("calls %+v", f.Calls())
	}
	if e := events(t, s, res.Run.ID, "linear"); !slices.Equal(e, []string{"Loam did not move ENG-523 to In Progress: that update to Linear is off"}) {
		t.Fatalf("linear events %q", e)
	}
}

func TestLinearUpdatesShowsAndSetsTheSwitches(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	type out struct {
		Updates store.LinearUpdates `json:"updates"`
	}
	read := func(args ...string) store.LinearUpdates {
		t.Helper()
		text, errOut, err := lrRun(t, "", append([]string{"linear", "updates", "--json"}, args...)...)
		if err != nil {
			t.Fatalf("%v %s", err, errOut)
		}
		var got out
		if err := json.Unmarshal([]byte(text), &got); err != nil {
			t.Fatalf("%v: %s", err, text)
		}
		return got.Updates
	}
	if got := read(); got != store.DefaultLinearUpdates {
		t.Fatalf("defaults %+v", got)
	}
	// A flag sets its switch and leaves the others.
	want := store.LinearUpdates{InProgress: true, AttachPR: true, Done: false, WalkthroughComment: true}
	if got := read("--done", "off", "--walkthrough", "on"); got != want {
		t.Fatalf("set %+v", got)
	}
	if got := read(); got != want {
		t.Fatalf("read back %+v", got)
	}
	if text, code := loam(t, "linear", "updates", "--done", "maybe", "--json"); code != ExitInvalid || !strings.Contains(text, "on or off") {
		t.Fatalf("exit %d: %s", code, text)
	}
	text, _, _ := lrRun(t, "", "linear", "updates")
	if !strings.Contains(text, "When you land a run, move the issue to Done: off\n") ||
		!strings.Contains(text, "When a run starts, move the issue to In Progress: on\n") {
		t.Fatalf("text %q", text)
	}
}
