package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

const intakeIssues = `{"issues": [
  {"number": 52, "title": "Paste a long prompt without a hang", "url": "https://github.com/example/widgets/issues/52",
   "labels": [], "updatedAt": "2026-10-22T09:00:00Z"},
  {"number": 48, "title": "Install fails when ~/.local/bin is missing", "url": "https://github.com/example/widgets/issues/48",
   "labels": [{"name": "bug"}], "updatedAt": "2026-10-20T10:00:00Z"}
]}`

// intakeCLI is runCLI with a map in the links of the plot: tickets 135 and
// 136 are open, and 99 is resolved. It returns the folder of the tickets.
func intakeCLI(t *testing.T) (*store.Store, store.Plot, string, string) {
	t.Helper()
	s, p, repo := wtCLI(t)
	testutil.FakeClaude(t)
	trustFolder(t, repo)
	dir := filepath.Join(t.TempDir(), "build")
	issues := filepath.Join(dir, "issues")
	if err := os.MkdirAll(issues, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{
		"map.md":                             "# Build\n",
		"issues/135-quit-during-a-merge.md":  "Status: open\nBlocked by: none\n\n# Driver scenario: quit during a merge\n",
		"issues/136-sheet-in-full-screen.md": "Status: open\nBlocked by: 135\n\n# Driver scenario: a sheet in full screen\n",
		"issues/99-home-space.md":            "Status: resolved\n\n# A Home space\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, errOut, err := lrRun(t, "", "link", "add", "alpha", "Build map", filepath.Join(dir, "map.md")); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	return s, p, repo, issues
}

func intakeList(t *testing.T) intake.Result {
	t.Helper()
	out, errOut, err := lrRun(t, "", "intake", "list", "alpha", "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res intake.Result
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return res
}

func TestRunStartFromATicketOfTheMap(t *testing.T) {
	_, _, _, issues := intakeCLI(t)
	ticket := filepath.Join(issues, "135-quit-during-a-merge.md")
	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Quit during a merge", "--ticket", ticket, "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var res runStartOut
	if err := json.Unmarshal([]byte(out), &res); err != nil {
		t.Fatal(err)
	}
	src := res.Run.Source
	if src == nil || src.Kind != "map" || src.Key != "map 135" || src.URL != ticket {
		t.Fatalf("source %+v", src)
	}
	if res.Worktree.Name != "map-135-quit-during-a-merge" {
		t.Fatalf("worktree %q", res.Worktree.Name)
	}
	args := testutil.FakeClaudeInvocation(t).Args
	if prompt := args[len(args)-1]; !strings.Contains(prompt, "map 135 ("+ticket+")") {
		t.Fatalf("prompt %q", prompt)
	}

	// A file that is not a ticket, and a ticket with a link, are refused.
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "X", "--ticket", filepath.Join(issues, "..", "map.md")); err == nil {
		t.Fatal("a map started as a ticket")
	}
	if _, _, err := lrRun(t, "", "run", "start", "alpha", "--title", "X", "--ticket", ticket,
		"--link", "https://github.com/example/widgets/issues/48"); err == nil {
		t.Fatal("a ticket and a link started")
	}
}

func TestIntakeListsTheIssuesAndTicketsOfAPlot(t *testing.T) {
	_, _, repo, issues := intakeCLI(t)
	ticket := filepath.Join(issues, "135-quit-during-a-merge.md")
	out, errOut, err := lrRun(t, "", "run", "start", "alpha", "--title", "Quit during a merge", "--ticket", ticket, "--json")
	if err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	var started runStartOut
	if err := json.Unmarshal([]byte(out), &started); err != nil {
		t.Fatal(err)
	}
	testutil.Git(t, repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(t, intakeIssues)

	res := intakeList(t)
	if len(res.Sources) != 2 || res.Sources[0] != (intake.Source{Kind: "github", Label: "example/widgets"}) ||
		res.Sources[1] != (intake.Source{Kind: "map", Label: "Build map"}) {
		t.Fatalf("sources %+v", res.Sources)
	}
	var keys []string
	for _, i := range res.Items {
		keys = append(keys, i.Key)
	}
	if strings.Join(keys, ",") != "#52,#48,map 135,map 136" {
		t.Fatalf("keys %v", keys)
	}
	if i := res.Items[1]; i.Source != "github" || i.Title != "Install fails when ~/.local/bin is missing" || i.Status != "Open" ||
		strings.Join(i.Labels, ",") != "bug" || i.URL != "https://github.com/example/widgets/issues/48" || i.RunID != "" {
		t.Fatalf("issue %+v", i)
	}
	if i := res.Items[2]; i.Source != "map" || i.URL != ticket || i.RunID != started.Run.ID {
		t.Fatalf("ticket %+v", i)
	}
	if i := res.Items[3]; i.Status != "Blocked by 135" || i.RunID != "" {
		t.Fatalf("blocked ticket %+v", i)
	}
}

func TestIntakeShowsTheMapWhenGitHubFails(t *testing.T) {
	_, _, repo, _ := intakeCLI(t)
	testutil.Git(t, repo, "remote", "set-url", "origin", "https://github.com/example/widgets.git")
	testutil.FakeGH(t, intakeIssues)
	t.Setenv("LOAM_FAKE_GH_FAIL", "rate_limited")

	res := intakeList(t)
	if len(res.Sources) != 2 || !strings.Contains(res.Sources[0].Error, "rate limit") || res.Sources[1].Error != "" {
		t.Fatalf("sources %+v", res.Sources)
	}
	if len(res.Items) != 2 || res.Items[0].Key != "map 135" {
		t.Fatalf("items %+v", res.Items)
	}
}
