package cli

import (
	"os/exec"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// Ticket TAS-62: a draft lists the work that it leaves out on purpose, and
// approve files each kept follow-up as an issue.

// followUpDraft is a draft with one follow-up. target is what Claude puts in
// the target of the follow-up.
func followUpDraft(target string) string {
	return strings.Replace(shapeDraft, `"plan"`, `"follow_ups": [{"title": "A picker for the window size", "body": "The app has no picker yet.", "target": "`+target+`"}],
  "plan"`, 1)
}

const linearIssueURL = "https://linear.app/acme/issue/ENG-523/plot-panel-drag"

// linearShape drafts a run from a Linear issue. It returns the fake Linear.
func linearShape(t *testing.T, target string) (*store.Store, store.Run, *testutil.FakeLinearServer) {
	t.Helper()
	s, _, _ := shapeCLI(t)
	f := testutil.FakeLinear(t)
	testutil.FakeClaudePrint(t, followUpDraft(target))
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot", "--link", linearIssueURL)
	return s, r, f
}

func TestRunShapeDraftsFollowUpsInTheProjectOfTheLinearIssue(t *testing.T) {
	_, r, f := linearShape(t, "")
	fus := r.Shape.FollowUps
	if len(fus) != 1 || fus[0].Title != "A picker for the window size" || fus[0].Body != "The app has no picker yet." ||
		!fus[0].Kept || fus[0].Filed != nil || fus[0].Target.Kind != store.TargetLinear || fus[0].Target.URL != "" {
		t.Fatalf("follow-ups %+v", fus)
	}
	if len(linearCalls(f, "issueCreate")) != 0 {
		t.Fatal("a draft filed an issue")
	}
}

func TestRunApproveFilesAKeptFollowUpAndLinksItToTheRun(t *testing.T) {
	s, r, f := linearShape(t, "")
	r = shapeRun(t, "approve", r.ID)

	creates := linearCalls(f, "issueCreate")
	if len(creates) != 1 {
		t.Fatalf("calls %+v", f.Calls())
	}
	input, _ := creates[0].Variables["input"].(map[string]any)
	if input["title"] != "A picker for the window size" || input["teamId"] != "team-eng" || input["projectId"] != "project-loam" ||
		!strings.Contains(input["description"].(string), "The app has no picker yet.") {
		t.Fatalf("input %+v", input)
	}
	// The new issue is related to the issue of the run.
	rel := linearCalls(f, "issueRelationCreate")
	if len(rel) != 1 || rel[0].Variables["issue"] != "id-ENG-601" || rel[0].Variables["related"] != "id-ENG-523" {
		t.Fatalf("relations %+v", rel)
	}
	got := r.Shape.FollowUps[0]
	if r.State != store.RunRunning || got.Filed == nil || got.Filed.Key != "ENG-601" || got.Error != "" {
		t.Fatalf("run %s, follow-up %+v", r.State, got)
	}
	if ev := events(t, s, r.ID, "followup"); len(ev) != 1 || !strings.Contains(ev[0], "ENG-601") {
		t.Fatalf("events %q", ev)
	}
}

func TestRunApproveFilesNothingForADroppedFollowUp(t *testing.T) {
	_, r, f := linearShape(t, "")
	if _, _, err := lrRun(t, "", "run", "approve", r.ID, "--drop-follow-up", "2"); err == nil || !strings.Contains(err.Error(), "no follow-up 2") {
		t.Fatalf("dropped a follow-up that is not there: %v", err)
	}
	r = shapeRun(t, "approve", r.ID, "--drop-follow-up", "1")
	if len(linearCalls(f, "issueCreate")) != 0 {
		t.Fatalf("calls %+v", f.Calls())
	}
	if got := r.Shape.FollowUps[0]; got.Kept || got.Filed != nil {
		t.Fatalf("follow-up %+v", got)
	}
}

func TestRunApproveStartsTheRunWhenAFollowUpCannotBeFiled(t *testing.T) {
	s, r, _ := linearShape(t, "")
	t.Setenv("LOAM_LINEAR_URL", "http://127.0.0.1:1")
	out, errOut, err := lrRun(t, "", "run", "approve", r.ID, "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	if !strings.Contains(errOut, "Could not file") {
		t.Errorf("no warning: %s", errOut)
	}
	r, err = s.GetRun(r.ID)
	if err != nil || r.State != store.RunRunning || r.Shape.FollowUps[0].Filed != nil ||
		!strings.Contains(r.Shape.FollowUps[0].Error, "Linear") {
		t.Fatalf("run %+v %v\n%s", r, err, out)
	}
	if ev := events(t, s, r.ID, "followup"); len(ev) != 1 || !strings.HasPrefix(ev[0], "Could not file") {
		t.Fatalf("events %q", ev)
	}
}

func TestRunShapeOffersTheLinearLinksOfThePlotAndRecordsThePick(t *testing.T) {
	shapeCLI(t)
	testutil.FakeLinear(t)
	for _, l := range [][2]string{{"Bugs", "https://linear.app/acme/project/bugs-aaaaaaaa1111/overview"},
		{"Roadmap", "https://linear.app/acme/project/roadmap-bbbbbbbb2222/overview"}} {
		if _, errOut, err := lrRun(t, "", "link", "add", "alpha", l[0], l[1]); err != nil {
			t.Fatalf("%v %s", err, errOut)
		}
	}
	testutil.FakeClaudePrint(t, followUpDraft("https://linear.app/acme/project/roadmap-bbbbbbbb2222/overview"))
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")

	prompt := argAfter(testutil.FakeClaudeInvocation(t).Args, "-p")
	for _, want := range []string{"Bugs: https://linear.app/acme/project/bugs-aaaaaaaa1111/overview", "Roadmap: https://linear.app/acme/project/roadmap-bbbbbbbb2222/overview"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt misses %q:\n%s", want, prompt)
		}
	}
	got := r.Shape.FollowUps[0].Target
	if got.Kind != store.TargetLinear || got.Label != "Roadmap" || !strings.HasSuffix(got.URL, "roadmap-bbbbbbbb2222/overview") {
		t.Fatalf("target %+v", got)
	}
	// A pick that is not one of the links gives the first link.
	testutil.FakeClaudePrint(t, followUpDraft("https://linear.app/other/project/x-cccccccc3333/overview"))
	r = shapeRun(t, "redraft", r.ID)
	if got := r.Shape.FollowUps[0].Target; got.Label != "Bugs" {
		t.Fatalf("target %+v", got)
	}
}

func TestRunApproveFilesAFollowUpOnGitHubWhenThePlotHasNoLinearLink(t *testing.T) {
	_, _, repo := shapeCLI(t)
	if out, err := exec.Command("git", "-C", repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git").CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	testutil.FakeGH(t, `{"issues": []}`)
	testutil.FakeClaudePrint(t, followUpDraft(""))
	r := shapeRun(t, "shape", "alpha", "--title", "Remember the window size per plot")
	if tg := r.Shape.FollowUps[0].Target; tg.Kind != store.TargetGitHub || tg.Label != "example/widgets" {
		t.Fatalf("target %+v", tg)
	}
	r = shapeRun(t, "approve", r.ID)

	var created [][]string
	for _, c := range testutil.FakeGHCalls(t) {
		if slices.Contains(c.Args, "issue") && slices.Contains(c.Args, "create") {
			created = append(created, c.Args)
		}
	}
	if len(created) != 1 || argAfter(created[0], "--repo") != "github.com/example/widgets" ||
		argAfter(created[0], "--title") != "A picker for the window size" {
		t.Fatalf("gh issue create calls %q", created)
	}
	if got := r.Shape.FollowUps[0]; got.Filed == nil || got.Filed.Key != "example/widgets#1" {
		t.Fatalf("follow-up %+v", got)
	}
}
