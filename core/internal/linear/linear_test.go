package linear_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func TestParseScope(t *testing.T) {
	for _, c := range []struct {
		url  string
		want linear.Scope
		ok   bool
	}{
		{"https://linear.app/acme/team/ENG/active", linear.Scope{Team: "ENG"}, true},
		{"https://linear.app/acme/team/eng/all", linear.Scope{Team: "ENG"}, true},
		{"https://linear.app/acme/project/loam-redesign-8f3a2b1c9d0e/overview", linear.Scope{Project: "8f3a2b1c9d0e"}, true},
		{"https://linear.app/acme/issue/ENG-523/drag-a-link", linear.Scope{}, false},
		{"https://github.com/example/widgets", linear.Scope{}, false},
	} {
		got, ok := linear.ParseScope(c.url)
		if got != c.want || ok != c.ok {
			t.Errorf("%s: %+v %v", c.url, got, ok)
		}
	}
}

func TestViewerChecksTheKey(t *testing.T) {
	f := testutil.FakeLinear(t)
	v, err := linear.NewClient(f.URL, testutil.LinearKey).Viewer(context.Background())
	if err != nil || v.Name != "Ada Example" || v.Organization != "Acme" {
		t.Fatalf("%+v %v", v, err)
	}
	if _, err := linear.NewClient(f.URL, "lin_api_bad").Viewer(context.Background()); !errors.Is(err, linear.ErrBadKey) {
		t.Fatalf("err %v", err)
	}
}

func TestIssuesOfATeamAreTheOpenOnes(t *testing.T) {
	f := testutil.FakeLinear(t)
	got, err := linear.NewClient(f.URL, testutil.LinearKey).Issues(context.Background(), linear.Scope{Team: "ENG"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Key != "ENG-523" || got[0].State != "Todo" || got[0].Priority != "High" ||
		strings.Join(got[0].Labels, ",") != "Feature" || got[0].URL != "https://linear.app/acme/issue/ENG-523/plot-panel-drag" ||
		got[1].Priority != "" || got[1].Labels == nil {
		t.Fatalf("%+v", got)
	}
	filter, _ := json.Marshal(f.Calls()[0].Variables["filter"])
	if !strings.Contains(string(filter), `"ENG"`) || !strings.Contains(string(filter), "completed") {
		t.Fatalf("filter %s", filter)
	}
}

func TestStartMovesAnIssueThatHasNotStarted(t *testing.T) {
	f := testutil.FakeLinear(t)
	c := linear.NewClient(f.URL, testutil.LinearKey)
	moved, err := c.Start(context.Background(), "ENG-523")
	if err != nil || moved != "In Progress" {
		t.Fatalf("%q %v", moved, err)
	}
	// The first started state by position, not the first in the list.
	if v := f.Calls()[1].Variables; v["state"] != "st-progress" || v["id"] != "ENG-523" {
		t.Fatalf("update vars %+v", v)
	}
	// An issue that has started stays where it is.
	moved, err = c.Start(context.Background(), "ENG-523")
	if err != nil || moved != "" || len(f.Calls()) != 3 {
		t.Fatalf("%q %v %d queries", moved, err, len(f.Calls()))
	}
}

// Ticket 206: Loam attaches the PR of a run to its issue.
func TestAttachLinksAURLToAnIssue(t *testing.T) {
	f := testutil.FakeLinear(t)
	c := linear.NewClient(f.URL, testutil.LinearKey)
	if err := c.Attach(context.Background(), "ENG-523", "https://github.com/example/widgets/pull/147", "PR #147"); err != nil {
		t.Fatal(err)
	}
	v := f.Calls()[0].Variables
	if v["id"] != "ENG-523" || v["url"] != "https://github.com/example/widgets/pull/147" || v["title"] != "PR #147" {
		t.Fatalf("vars %+v", v)
	}
}
