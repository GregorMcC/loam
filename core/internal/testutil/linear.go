package testutil

import (
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
// priority). An update moves ENG-523 to In Progress. It is an
// [http.Handler], so the fakelinear command can serve it for the app's
// driver too.
type FakeLinearServer struct {
	// URL is the address of the server that [FakeLinear] started.
	URL string
	mu  sync.Mutex
	// calls are the requests so far, oldest first.
	calls   []LinearCall
	started bool
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
	state, stateType := "Todo", "unstarted"
	if f.started {
		state, stateType = "In Progress", "started"
	}
	switch {
	case strings.Contains(req.Query, "viewer"):
		io.WriteString(w, `{"data":{"viewer":{"name":"Ada Example","email":"ada@example.com"},"organization":{"name":"Acme"}}}`)
	case strings.Contains(req.Query, "issueUpdate"):
		f.started = true
		io.WriteString(w, `{"data":{"issueUpdate":{"success":true}}}`)
	case strings.Contains(req.Query, "issue(id"):
		io.WriteString(w, `{"data":{"issue":{"state":{"type":"`+stateType+`"},
			"team":{"states":{"nodes":[{"id":"st-review","name":"In Review","position":2},{"id":"st-progress","name":"In Progress","position":1}]}}}}}`)
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
