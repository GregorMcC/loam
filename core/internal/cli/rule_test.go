package cli

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/run"
	"github.com/GregorMcC/loam/core/internal/store"
)

// Ticket 209: rules. A note that you send back on two runs becomes a rule: a
// check that the gate runs on every run of the plot.

func sendBackOffer(t *testing.T, args ...string) (*run.RuleOffer, string) {
	t.Helper()
	out, code := loam(t, append([]string{"run", "send-back"}, append(args, "--json")...)...)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got struct {
		RuleOffer *run.RuleOffer `json:"rule_offer"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return got.RuleOffer, out
}

// earlierNote records a run of the plot that you sent a note back on.
func earlierNote(t *testing.T, s *store.Store, plotID, note string) store.Run {
	t.Helper()
	r, err := s.AddRun(store.Run{PlotID: plotID, Folder: t.TempDir(), Title: "An earlier run", Goal: "Do it.", State: store.RunLanded, MaxTries: 3})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.AddRunEvent(r.ID, "note", note); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestRunSendBackRecordsEachNote(t *testing.T) {
	s, r, _ := readyRun(t)
	offer, out := sendBackOffer(t, r.ID, "--note", "README.md:3: Keep the README short.", "--note", "Add a test.")
	if offer != nil {
		t.Fatalf("an offer with no earlier note: %s", out)
	}
	if e := events(t, s, r.ID, "note"); !slices.Equal(e, []string{"README.md line 3: Keep the README short.", "Add a test."}) {
		t.Fatalf("note events %q", e)
	}
}

func TestRunSendBackOffersARuleForANoteLikeAnEarlierOne(t *testing.T) {
	s, r, _ := readyRun(t)
	earlier := earlierNote(t, s, r.PlotID, "docs/a.md line 4: Keep the README short and plain.")
	earlierNote(t, s, r.PlotID, "Rename the flag.")
	offer, out := sendBackOffer(t, r.ID, "--note", "Add a test.", "--note", "Please keep the README short.")
	want := run.RuleOffer{Note: "Please keep the README short.", Earlier: "Keep the README short and plain.",
		EarlierRunID: earlier.ID, EarlierTitle: "An earlier run"}
	if offer == nil || *offer != want {
		t.Fatalf("offer %+v: %s", offer, out)
	}
}

func TestRunSendBackOffersNoRuleForANoteThatIsNotLikeAnEarlierOne(t *testing.T) {
	s, r, _ := readyRun(t)
	earlierNote(t, s, r.PlotID, "Keep the README short.")
	if offer, out := sendBackOffer(t, r.ID, "--note", "Keep the test names short."); offer != nil {
		t.Fatalf("offer %+v: %s", offer, out)
	}
}

func TestRunSendBackOffersNoRuleThatThePlotHas(t *testing.T) {
	s, r, _ := readyRun(t)
	earlierNote(t, s, r.PlotID, "Keep the README short.")
	if _, err := s.AddRule(store.Rule{PlotID: r.PlotID, Name: "Short README", Command: "true", Note: "Keep the README short."}); err != nil {
		t.Fatal(err)
	}
	if offer, out := sendBackOffer(t, r.ID, "--note", "Keep the README short, please."); offer != nil {
		t.Fatalf("offer %+v: %s", offer, out)
	}
}

func ruleCmd(t *testing.T, args ...string) (map[string]json.RawMessage, int, string) {
	t.Helper()
	out, code := loam(t, append([]string{"rule"}, append(args, "--json")...)...)
	var got map[string]json.RawMessage
	if code == 0 {
		if err := json.Unmarshal([]byte(out), &got); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}
	return got, code, out
}

func TestRuleAddListAndRemove(t *testing.T) {
	_, p := runCLI(t)
	got, code, out := ruleCmd(t, "add", p.Name, "--name", "Short README", "--command", "test $(wc -l < README.md) -lt 40",
		"--note", "Keep the README short.")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var added store.Rule
	if err := json.Unmarshal(got["rule"], &added); err != nil || added.ID == "" || added.PlotID != p.ID ||
		added.Name != "Short README" || added.Note != "Keep the README short." {
		t.Fatalf("%v: %s", err, out)
	}
	got, code, out = ruleCmd(t, "list", p.Name)
	var list []store.Rule
	if err := json.Unmarshal(got["rules"], &list); code != 0 || err != nil || len(list) != 1 || list[0].ID != added.ID {
		t.Fatalf("list: exit %d: %s", code, out)
	}
	if _, code, out = ruleCmd(t, "rm", added.ID); code != 0 {
		t.Fatalf("rm: exit %d: %s", code, out)
	}
	got, _, _ = ruleCmd(t, "list")
	if string(got["rules"]) != "[]" {
		t.Fatalf("after rm: %s", got["rules"])
	}
}

func TestRuleAddNeedsANameAndACommand(t *testing.T) {
	_, p := runCLI(t)
	if _, code, out := ruleCmd(t, "add", p.Name, "--name", "Short README"); code != ExitInvalid {
		t.Fatalf("exit %d: %s", code, out)
	}
}

func TestTheGateRunsTheRulesOfThePlot(t *testing.T) {
	s, r := gateRun(t, "3")
	if _, code, out := ruleCmd(t, "add", r.PlotID, "--name", "No TODO", "--command", "! grep -q TODO hello.txt"); code != 0 {
		t.Fatalf("exit %d: %s", code, out)
	}
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\nTODO\n")
	code, reason := stopHook(t, r, "Stop")
	if code != 2 || !strings.Contains(reason, "Rule: No TODO") {
		t.Fatalf("code %d, reason:\n%s", code, reason)
	}
	writeAndCommit(t, r.Folder, "hello.txt", "hi there\n")
	if code, reason = stopHook(t, r, "Stop"); code != 0 {
		t.Fatalf("passing gate: code %d, reason:\n%s", code, reason)
	}
	if got, _ := s.GetRun(r.ID); !strings.HasPrefix(got.Note, "All 3 checks passed") {
		t.Fatalf("%+v", got)
	}
}

func TestARunPromptNamesTheRulesOfThePlot(t *testing.T) {
	r := store.Run{Goal: "Say hi.", DoneWhen: []store.Check{{Name: "Hello", Command: "true"}}}
	got := run.Prompt(r, []store.Rule{{Name: "No TODO", Command: "! grep -rq TODO ."}})
	for _, want := range []string{"Hello: `true`", "Rule: No TODO: `! grep -rq TODO .`", "every run must pass them"} {
		if !strings.Contains(got, want) {
			t.Errorf("the prompt misses %q:\n%s", want, got)
		}
	}
}
