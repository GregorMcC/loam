package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-38: the PR body follows the PR template of the repo.

const prTemplateText = "## Summary\n\n<!-- What changed, and why. -->\n\n## Testing\n\n- [ ] Tests pass\n- [ ] Checked by hand\n"

// templateAnswer is what claude -p prints for a PR text and the ship notes:
// the result message of --output-format json.
const templateAnswer = `{"type": "result", "subtype": "success", "is_error": false, "result": "",
 "structured_output": {"title": "Greet the user", "body": "## Summary\n\nAdds hello.txt.\n\n## Testing\n\n- [x] Tests pass\n- [ ] Checked by hand",
  "walkthrough": "Adds hello.txt, which greets the user.", "files": [{"path": "hello.txt", "role": "The greeting"}],
  "risk": {"level": "low", "reasons": ["One new file."]}, "where_it_stands": "The greeting is in."}}`

// openedPR returns the PR that the fake gh got from pr create.
func openedPR(t *testing.T) (title, body string) {
	t.Helper()
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err != nil {
		t.Fatal(err)
	}
	var st struct {
		Pulls []struct{ Title, Body string } `json:"pulls"`
	}
	if err := json.Unmarshal(b, &st); err != nil || len(st.Pulls) != 1 {
		t.Fatalf("%v: %s", err, b)
	}
	return st.Pulls[0].Title, st.Pulls[0].Body
}

func writeTemplate(t *testing.T, folder, rel, text string) {
	t.Helper()
	path := filepath.Join(folder, rel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunTickOpensThePRWithTheBodyThatClaudeFilledIn(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, templateAnswer)
	writeTemplate(t, r.Folder, ".github/pull_request_template.md", prTemplateText)
	if _, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		r.Source = &store.RunSource{Kind: "linear", Key: "ENG-523", URL: "https://linear.app/acme/issue/ENG-523/x"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	testutil.FakeLinear(t)
	tick(t)

	title, body := openedPR(t)
	want := "## Summary\n\nAdds hello.txt.\n\n## Testing\n\n- [x] Tests pass\n- [ ] Checked by hand\n\n" +
		"Linear: ENG-523\n\nLoam opened this PR for a run whose checks passed.\n"
	if title != "Greet the user" || body != want {
		t.Fatalf("title %q body %q", title, body)
	}
	calls := printCalls(t)
	if len(calls) != 1 {
		t.Fatalf("claude -p calls %q", calls)
	}
	args := calls[0]
	for _, want := range [][]string{{"--output-format", "json"}, {"--tools", "Read,Grep,Glob"}, {"--no-session-persistence"}, {"--json-schema"},
		{"--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`}} {
		if !containsRun(args, want) {
			t.Errorf("args %q miss %q", args, want)
		}
	}
	prompt := args[slices.Index(args, "-p")+1]
	for _, want := range []string{"## Summary", "<!-- What changed, and why. -->", "Say hi", "Hello", "grep -qx 'hi there' hello.txt", "Write hello.txt", "hello.txt"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("the prompt misses %q:\n%s", want, prompt)
		}
	}
	inv := testutil.FakeClaudeInvocation(t)
	if realPath(t, inv.Cwd) != realPath(t, r.Folder) {
		t.Fatalf("cwd %s", inv.Cwd)
	}
	// The same call wrote the ship notes.
	if got, _ := s.GetRun(r.ID); got.Notes == nil || got.Notes.Walkthrough != "Adds hello.txt, which greets the user." {
		t.Fatalf("notes %+v", got.Notes)
	}
}

func TestRunTickKeepsTheOldBodyWhenClaudeFailsOnATemplate(t *testing.T) {
	s, r, w := shipRun(t, "3")
	trustFolder(t, r.Folder, w.Repo)
	testutil.FakeClaudePrint(t, `{"type": "result", "subtype": "error_max_turns", "is_error": true, "result": "Claude ran out of turns"}`)
	writeTemplate(t, r.Folder, "docs/Pull_Request_Template.md", prTemplateText)
	tick(t)

	title, body := openedPR(t)
	if title != "Say hi" || !strings.HasPrefix(body, "Say hi\n\n## Done when\n\n- Hello: `grep -qx 'hi there' hello.txt`\n- Work committed\n") ||
		!strings.HasSuffix(body, "\nLoam opened this PR for a run whose checks passed.\n") {
		t.Fatalf("title %q body %q", title, body)
	}
	e := events(t, s, r.ID, "ship")
	if !slices.ContainsFunc(e, func(d string) bool {
		return strings.HasPrefix(d, "Loam used no PR template") && strings.Contains(d, "Claude ran out of turns")
	}) {
		t.Fatalf("ship events %q", e)
	}
}

func TestRunTickKeepsTheOldBodyWhenTheFolderIsNotTrusted(t *testing.T) {
	s, r, _ := shipRun(t, "3")
	trustFolder(t)
	// A review in a folder that is not trusted stops the run, so this test has none.
	if _, errOut, err := lrRun(t, "", "run", "defaults", "alpha", "--review", "off"); err != nil {
		t.Fatalf("%v %s", err, errOut)
	}
	testutil.FakeClaudePrint(t, templateAnswer)
	writeTemplate(t, r.Folder, ".github/PULL_REQUEST_TEMPLATE/default.md", prTemplateText)
	tick(t)
	if title, body := openedPR(t); title != "Say hi" || !strings.HasPrefix(body, "Say hi\n\n## Done when") {
		t.Fatalf("title %q body %q", title, body)
	}
	if len(printCalls(t)) != 0 {
		t.Fatalf("claude -p ran in a folder that is not trusted")
	}
	if e := events(t, s, r.ID, "ship"); !slices.ContainsFunc(e, func(d string) bool { return strings.HasPrefix(d, "Loam used no PR template") }) {
		t.Fatalf("ship events %q", e)
	}
}
