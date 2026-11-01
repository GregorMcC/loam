package cli_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func linkLabels(e *env, plot string) string {
	var l []string
	for _, k := range e.show(plot).Links {
		l = append(l, k.Label)
	}
	return strings.Join(l, " ")
}

func addLinks(e *env, plot string, labels ...string) {
	for _, l := range labels {
		e.ok("", "link", "add", plot, l, "https://example.com/"+l)
	}
}

func TestLinkMove(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	addLinks(e, p.ID, "A", "B", "C")
	var out struct {
		ChangeID int64      `json:"change_id"`
		Link     store.Link `json:"link"`
	}
	if err := json.Unmarshal([]byte(e.ok("", "link", "move", p.ID, "C", "1", "--json")), &out); err != nil {
		t.Fatal(err)
	}
	if out.ChangeID == 0 || out.Link.Label != "C" || out.Link.Position != 1 {
		t.Fatalf("output %+v", out)
	}
	if got := linkLabels(e, p.ID); got != "C A B" {
		t.Fatalf("links %q", got)
	}
}

func TestLinkMoveByLabelText(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	addLinks(e, p.ID, "A", "B", "C")
	if got := strings.TrimSpace(e.ok("", "link", "move", p.ID, "C", "1")); got != "C is now link 1" {
		t.Fatalf("text %q", got)
	}
	if got := strings.TrimSpace(e.ok("", "link", "move", p.ID, "C", "1")); got != "No change." {
		t.Fatalf("text %q", got)
	}
}

func TestLinkMoveBadPosition(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	addLinks(e, p.ID, "A", "B")
	e.failJSON(2, "invalid", "link", "move", p.ID, "A", "9")
	e.failJSON(2, "invalid", "link", "move", p.ID, "A", "first")
}

func TestLinkMoveStale(t *testing.T) {
	e := newEnv(t)
	p := e.newPlot("alpha")
	addLinks(e, p.ID, "A", "B", "C")
	old := e.show(p.ID).Versions[store.ItemLinkOrder]
	e.ok("", "link", "move", p.ID, "C", "1")
	e.failJSON(10, "stale", "link", "move", p.ID, "A", "3", "--expect", store.ItemLinkOrder+"="+itoa(old))
}
