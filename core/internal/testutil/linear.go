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
// priority). An update moves ENG-523 to the state that it names, such as In
// Progress or Done, an attachment link and a comment succeed, and ENG-523
// has a description. It is an
// [http.Handler], so the fakelinear command can serve it for the app's
// driver too.
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
	if r.Header.Get("Authorization") != LinearKey {
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, `{"errors":[{"message":"Authentication required, not authenticated"}]}`)
		return
	}
	var req struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, LinearCall{Query: req.Query, Variables: req.Variables})
	state, stateType := fakeStateOf(f.stateID)
	switch {
	case strings.Contains(req.Query, "viewer"):
		io.WriteString(w, `{"data":{"viewer":{"name":"Ada Example","email":"ada@example.com"},"organization":{"name":"Acme"}}}`)
	case strings.Contains(req.Query, "attachmentLinkURL"):
		io.WriteString(w, `{"data":{"attachmentLinkURL":{"success":true}}}`)
	case strings.Contains(req.Query, "commentCreate"):
		io.WriteString(w, `{"data":{"commentCreate":{"success":true}}}`)
	case strings.Contains(req.Query, "issueUpdate"):
		f.stateID, _ = req.Variables["state"].(string)
		io.WriteString(w, `{"data":{"issueUpdate":{"success":true}}}`)
	case strings.Contains(req.Query, "description"):
		io.WriteString(w, `{"data":{"issue":{"title":"Plot panel: drag a link to reorder it",
			"description":"A link in the plot panel moves to a new place when you drag it."}}}`)
	case strings.Contains(req.Query, "issue(id"):
		to, _ := req.Variables["type"].(string)
		io.WriteString(w, `{"data":{"issue":{"state":{"type":"`+stateType+`"},
			"team":{"states":{"nodes":`+cmp.Or(fakeStates[to], "[]")+`}}}}}`)
	case strings.Contains(req.Query, "issues("):
		io.WriteString(w, `{"data":{"issues":{"nodes":[
			{"identifier":"ENG-523","title":"Plot panel: drag a link to reorder it","url":"https://linear.app/acme/issue/ENG-523/plot-panel-drag",
			 "priorityLabel":"High","updatedAt":"2026-10-20T10:00:00.000Z","state":{"name":"`+state+`"},"labels":{"nodes":[{"name":"Feature"}]}},
			{"identifier":"ENG-525","title":"Settings: choose the worktree folder","url":"https://linear.app/acme/issue/ENG-525/settings",
			 "priorityLabel":"No priority","updatedAt":"2026-10-19T10:00:00.000Z","state":{"name":"Backlog"},"labels":{"nodes":[]}}]}}}`)
	default:
		w.WriteHeader(http.StatusBadRequest)
		io.WriteString(w, `{"errors":[{"message":"fake Linear: unknown query"}]}`)
	}
}
