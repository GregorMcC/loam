package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func linearStatusOf(t *testing.T, out string) linear.Status {
	t.Helper()
	var st linear.Status
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return st
}

func TestLinearKeyIsCheckedThenStored(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	testutil.FakeLinear(t)
	secrets := filepath.Join(t.TempDir(), "secrets.json")
	t.Setenv("LOAM_SECRETS_FILE", secrets)

	out, _, err := lrRun(t, "", "linear", "status", "--json")
	if err != nil || linearStatusOf(t, out).Connected {
		t.Fatalf("no key: %v %s", err, out)
	}
	// A key that Linear refuses is not stored.
	if _, _, err := lrRun(t, "lin_api_bad\n", "linear", "key", "set", "--json"); err == nil {
		t.Fatal("a bad key was taken")
	}
	if _, err := os.Stat(secrets); err == nil {
		t.Fatal("a bad key was stored")
	}
	out, _, err = lrRun(t, testutil.LinearKey+"\n", "linear", "key", "set", "--json")
	if st := linearStatusOf(t, out); err != nil || !st.Connected || st.Viewer == nil || st.Viewer.Name != "Ada Example" {
		t.Fatalf("set: %v %+v", err, st)
	}
	if b, _ := os.ReadFile(secrets); !strings.Contains(string(b), testutil.LinearKey) {
		t.Fatalf("stored %s", b)
	}
	out, _, _ = lrRun(t, "", "linear", "status", "--json")
	if st := linearStatusOf(t, out); !st.Connected || st.Viewer.Organization != "Acme" {
		t.Fatalf("status %+v", st)
	}
	out, _, err = lrRun(t, "", "linear", "key", "rm", "--json")
	if err != nil || linearStatusOf(t, out).Connected {
		t.Fatalf("rm: %v %s", err, out)
	}
}

func TestIntakeListsTheLinearIssuesOfATeamLink(t *testing.T) {
	intakeCLI(t)
	testutil.FakeLinear(t)
	if _, errOut, err := lrRun(t, "", "link", "add", "alpha", "ENG team", "https://linear.app/acme/team/ENG/active"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	res := intakeList(t)
	if len(res.Sources) == 0 || res.Sources[0].Kind != "linear" || res.Sources[0].Label != "ENG team" || res.Sources[0].Error != "" {
		t.Fatalf("sources %+v", res.Sources)
	}
	i := res.Items[0]
	if i.Source != "linear" || i.Key != "ENG-523" || i.Status != "Todo" || i.Priority != "High" ||
		strings.Join(i.Labels, ",") != "Feature" || i.URL != "https://linear.app/acme/issue/ENG-523/plot-panel-drag" {
		t.Fatalf("item %+v", i)
	}
	if i.Text == "" || i.Branch != "ada/eng-523-plot-panel-drag" || i.CreatedAt != "2026-10-01T09:30:00.000Z" || !i.InCycle || !i.AssignedToMe {
		t.Fatalf("new fields %+v", i)
	}
	if res.Items[1].Key != "ENG-525" || res.Items[1].Priority != "" || res.Items[1].Text != "" || res.Items[1].AssignedToMe {
		t.Fatalf("second %+v", res.Items[1])
	}

	// With no key, the source says so, and the map still shows.
	t.Setenv("LOAM_SECRETS_FILE", filepath.Join(t.TempDir(), "none.json"))
	res = intakeList(t)
	if !strings.Contains(res.Sources[0].Error, "no Linear API key") || res.Items[0].Source != "map" {
		t.Fatalf("no key: %+v %+v", res.Sources, res.Items)
	}
}

func TestRunStartMovesItsLinearIssueToInProgress(t *testing.T) {
	s, _ := runCLI(t)
	f := testutil.FakeLinear(t)
	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Drag a link",
		"--link", "https://linear.app/acme/issue/ENG-523/plot-panel-drag", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res runStartOut
	json.Unmarshal([]byte(out), &res)
	if src := res.Run.Source; src == nil || src.Kind != "linear" || src.Key != "ENG-523" {
		t.Fatalf("source %+v", src)
	}
	var moved bool
	for _, c := range f.Calls() {
		moved = moved || strings.Contains(c.Query, "issueUpdate")
	}
	if !moved {
		t.Fatalf("calls %+v", f.Calls())
	}
	events, _ := s.RunEvents(res.Run.ID)
	var noted bool
	for _, e := range events {
		noted = noted || (e.Kind == "linear" && e.Detail == "Moved ENG-523 to In Progress")
	}
	if !noted {
		t.Fatalf("events %+v", events)
	}
}

func TestRunStartGoesOnWhenLinearFails(t *testing.T) {
	s, _ := runCLI(t)
	testutil.FakeLinear(t)
	t.Setenv("LOAM_LINEAR_URL", "http://127.0.0.1:1")
	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Drag a link",
		"--link", "https://linear.app/acme/issue/ENG-523/plot-panel-drag", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res runStartOut
	json.Unmarshal([]byte(out), &res)
	if res.Run.State != "running" {
		t.Fatalf("state %s", res.Run.State)
	}
	events, _ := s.RunEvents(res.Run.ID)
	if last := events[len(events)-1]; last.Kind != "linear" || !strings.Contains(last.Detail, "Could not move ENG-523") {
		t.Fatalf("events %+v", events)
	}
}
