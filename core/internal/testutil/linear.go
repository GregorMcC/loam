package testutil

import (
	"cmp"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// LinearKey is the API key that [FakeLinear] accepts.
const LinearKey = "lin_api_good"

// LinearCall is one request to [FakeLinear].
type LinearCall struct {
	Query     string
	Variables map[string]any
}

// FakeLinearServer stands in for the Linear API. Team ENG has two open
// issues: ENG-523 (Todo, High, label Feature) and ENG-525 (Backlog, no
// priority). ENG-523 is in the active cycle, in milestone Beta, and assigned
// to the viewer, Ada Example. ENG-525 is in milestone Alpha, which comes
// before Beta, and assigned to Bob Example. An update moves ENG-523 to the state that it names, such as In
// Progress or Done, an attachment link and a comment succeed, and
// ENG-523 has a description. It is an
// [http.Handler], so the fakelinear command can serve it for the app's
// driver too.
//
// With LOAM_FAKE_LINEAR_ISSUES set to a JSON file, the issues are the issue
// nodes of that file instead, in the shape that Linear gives them. A query
// for a team gets the nodes whose identifier starts with the team key, and
// the text of an issue comes from its node. Each issue of the file reads as
// not started, so a run moves it to In Progress.
type FakeLinearServer struct {
	// URL is the address of the server that [FakeLinear] started.
	URL string
	mu  sync.Mutex
	// calls are the requests so far, oldest first.
	calls []LinearCall
	// stateID is the state that the last update of ENG-523 set. Empty is Todo.
	stateID string
}

// fakeStates are the workflow states of the team, by type, out of position
// order. Each ID is the state's ID in an update.
var fakeStates = map[string]string{
	"started":   `[{"id":"st-review","name":"In Review","position":2},{"id":"st-progress","name":"In Progress","position":1}]`,
	"completed": `[{"id":"st-done","name":"Done","position":1}]`,
}

// fakeStateOf is the name and type of a state ID.
func fakeStateOf(id string) (name, stateType string) {
	switch id {
	case "st-progress":
		return "In Progress", "started"
	case "st-review":
		return "In Review", "started"
	case "st-done":
		return "Done", "completed"
	}
	return "Todo", "unstarted"
}

// Calls returns the requests so far.
func (f *FakeLinearServer) Calls() []LinearCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]LinearCall(nil), f.calls...)
}

// FakeLinear starts a fake Linear API, points LOAM_LINEAR_URL at it, and
// stores [LinearKey] in a temp secrets file (LOAM_SECRETS_FILE). Set
// LOAM_SECRETS_FILE again to test a missing key.
func FakeLinear(t *testing.T) *FakeLinearServer {
	t.Helper()
	f := &FakeLinearServer{}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	f.URL = srv.URL
	t.Setenv("LOAM_LINEAR_URL", srv.URL)
	file := filepath.Join(t.TempDir(), "secrets.json")
	if err := os.WriteFile(file, []byte(`{"linear-api-key":"`+LinearKey+`"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LOAM_SECRETS_FILE", file)
	return f
}

// ServeHTTP answers one request as Linear does.
func (f *FakeLinearServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// A failed write shows in the client under test, so the fake ignores it.
	reply := func(body string) { _, _ = io.WriteString(w, body) }
	replyJSON := func(v any) { _ = json.NewEncoder(w).Encode(v) }
	if r.Header.Get("Authorization") != LinearKey {
		w.WriteHeader(http.StatusUnauthorized)
		reply(`{"errors":[{"message":"Authentication required, not authenticated"}]}`)
		return
	}
	var req struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req) // A bad body gets the unknown-query answer.
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, LinearCall{Query: req.Query, Variables: req.Variables})
	state, stateType := fakeStateOf(f.stateID)
	switch {
	case strings.Contains(req.Query, "issues(") && os.Getenv("LOAM_FAKE_LINEAR_ISSUES") != "":
		// The key of a team filter: {"team": {"key": {"eq": "SHOP"}}}. A project filter gets every node.
		var team string
		if b, err := json.Marshal(req.Variables["filter"]); err == nil {
			var f struct {
				Team struct{ Key struct{ Eq string } }
			}
			_ = json.Unmarshal(b, &f)
			team = f.Team.Key.Eq
		}
		nodes := []map[string]any{}
		for _, n := range fileIssues() {
			if id, _ := n["identifier"].(string); team == "" || strings.HasPrefix(id, team+"-") {
				nodes = append(nodes, n)
			}
		}
		replyJSON(map[string]any{"data": map[string]any{"viewer": map[string]any{"id": "user-ada"},
			"issues": map[string]any{"nodes": nodes}}})
	case strings.Contains(req.Query, "issues("):
		reply(`{"data":{"viewer":{"id":"user-ada"},"issues":{"nodes":[
			{"identifier":"ENG-523","title":"Plot panel: drag a link to reorder it","url":"https://linear.app/acme/issue/ENG-523/plot-panel-drag",
			 "priorityLabel":"High","updatedAt":"2026-10-20T10:00:00.000Z","createdAt":"2026-10-01T09:30:00.000Z",
			 "description":"A link in the plot panel moves to a new place when you drag it.","branchName":"ada/eng-523-plot-panel-drag",
			 "cycle":{"isActive":true},"assignee":{"id":"user-ada","name":"Ada Example"},
			 "state":{"name":"` + state + `","type":"` + stateType + `"},"projectMilestone":{"name":"Beta","sortOrder":2},
			 "labels":{"nodes":[{"name":"Feature"}]}},
			{"identifier":"ENG-525","title":"Settings: choose the worktree folder","url":"https://linear.app/acme/issue/ENG-525/settings",
			 "priorityLabel":"No priority","updatedAt":"2026-10-19T10:00:00.000Z","createdAt":"2026-10-02T11:00:00.000Z",
			 "description":null,"branchName":"ada/eng-525-settings","cycle":null,"assignee":{"id":"user-bob","name":"Bob Example"},
			 "state":{"name":"Backlog","type":"backlog"},"projectMilestone":{"name":"Alpha","sortOrder":1},"labels":{"nodes":[]}}]}}}`)
	case strings.Contains(req.Query, "viewer"):
		reply(`{"data":{"viewer":{"name":"Ada Example","email":"ada@example.com"},"organization":{"name":"Acme"}}}`)
	case strings.Contains(req.Query, "attachmentLinkURL"):
		reply(`{"data":{"attachmentLinkURL":{"success":true}}}`)
	case strings.Contains(req.Query, "commentCreate"):
		reply(`{"data":{"commentCreate":{"success":true}}}`)
	case strings.Contains(req.Query, "issueUpdate"):
		f.stateID, _ = req.Variables["state"].(string)
		reply(`{"data":{"issueUpdate":{"success":true}}}`)
	case strings.Contains(req.Query, "description") && os.Getenv("LOAM_FAKE_LINEAR_ISSUES") != "":
		issue := map[string]any{}
		for _, n := range fileIssues() {
			if n["identifier"] == req.Variables["id"] {
				issue = map[string]any{"title": n["title"], "description": n["description"]}
			}
		}
		replyJSON(map[string]any{"data": map[string]any{"issue": issue}})
	case strings.Contains(req.Query, "description"):
		reply(`{"data":{"issue":{"title":"Plot panel: drag a link to reorder it",
			"description":"A link in the plot panel moves to a new place when you drag it."}}}`)
	case strings.Contains(req.Query, "issue(id"):
		if os.Getenv("LOAM_FAKE_LINEAR_ISSUES") != "" {
			// An issue of the file has not started, so a run moves it.
			stateType = "unstarted"
		}
		to, _ := req.Variables["type"].(string)
		reply(`{"data":{"issue":{"state":{"type":"` + stateType + `"},
			"team":{"states":{"nodes":` + cmp.Or(fakeStates[to], "[]") + `}}}}}`)
	default:
		w.WriteHeader(http.StatusBadRequest)
		reply(`{"errors":[{"message":"fake Linear: unknown query"}]}`)
	}
}

// fileIssues reads the issue nodes of the file in LOAM_FAKE_LINEAR_ISSUES.
// A file that is missing or not JSON gives no issues.
func fileIssues() []map[string]any {
	var nodes []map[string]any
	if b, err := os.ReadFile(os.Getenv("LOAM_FAKE_LINEAR_ISSUES")); err == nil {
		_ = json.Unmarshal(b, &nodes)
	}
	return nodes
}
