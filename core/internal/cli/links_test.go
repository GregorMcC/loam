package cli

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
)

func TestLinkAddEditRm(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{})
	if _, _, err := lrRun(t, "", "link", "add", "alpha", "Docs", "https://example.com", "--note", "start here"); err != nil {
		t.Fatal(err)
	}
	got := lrPlot(t, s, p.ID)
	if len(got.Links) != 1 || got.Links[0].Label != "Docs" || got.Links[0].Target != "https://example.com" || got.Links[0].Note != "start here" {
		t.Fatalf("links %+v", got.Links)
	}
	id := got.Links[0].ID
	b, err := os.ReadFile(seed.Path(s, p.ID))
	if err != nil || !strings.Contains(string(b), "https://example.com") {
		t.Fatalf("seed: %v %s", err, b)
	}
	chs, _ := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
	if len(chs) != 1 || chs[0].Actor.Kind != store.ActorCLI {
		t.Fatalf("changes %+v", chs)
	}

	if _, _, err := lrRun(t, "", "link", "edit", "alpha", "Docs", "--target", "https://example.org"); err != nil {
		t.Fatal(err)
	}
	l := lrPlot(t, s, p.ID).Links[0]
	if l.Target != "https://example.org" || l.Label != "Docs" || l.Note != "start here" {
		t.Fatalf("link %+v", l)
	}
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", id, "--label", "Manual", "--note", ""); err != nil {
		t.Fatal(err)
	}
	l = lrPlot(t, s, p.ID).Links[0]
	if l.Label != "Manual" || l.Note != "" {
		t.Fatalf("link %+v", l)
	}
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", id); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("err %v", err)
	}

	if _, _, err := lrRun(t, "", "link", "rm", "alpha", "Manual"); err != nil {
		t.Fatal(err)
	}
	if n := len(lrPlot(t, s, p.ID).Links); n != 0 {
		t.Fatalf("%d links", n)
	}
	if _, _, err := lrRun(t, "", "link", "rm", "alpha", "Manual"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("err %v", err)
	}
}

func TestLinkAmbiguousLabel(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{Links: []store.LinkInput{{Label: "Docs", Target: "https://a"}, {Label: "Docs", Target: "https://b"}}})
	if _, _, err := lrRun(t, "", "link", "rm", "alpha", "Docs"); !errors.Is(err, ErrAmbiguous) {
		t.Fatalf("err %v", err)
	}
	if n := len(lrPlot(t, s, p.ID).Links); n != 2 {
		t.Fatalf("%d links", n)
	}
	id := lrPlot(t, s, p.ID).Links[0].ID
	if _, _, err := lrRun(t, "", "link", "rm", "alpha", id); err != nil {
		t.Fatal(err)
	}
}

func TestLinkStaleExpect(t *testing.T) {
	s, p := linkRepoEnv(t, store.PlotInput{Links: []store.LinkInput{{Label: "Docs", Target: "https://a"}}})
	l := p.Links[0]
	item := "link:" + l.ID
	if _, _, err := lrRun(t, "", "link", "edit", "alpha", l.ID, "--note", "x"); err != nil {
		t.Fatal(err)
	}
	_, _, err := lrRun(t, "", "link", "edit", "alpha", l.ID, "--note", "y", "--expect", item+"=1")
	var stale *store.StaleError
	if !errors.As(err, &stale) {
		t.Fatalf("err %v", err)
	}
	if lrPlot(t, s, p.ID).Links[0].Note != "x" {
		t.Fatal("stale write went through")
	}
	v := lrPlot(t, s, p.ID).Versions[item]
	if _, _, err := lrRun(t, "", "link", "rm", "alpha", l.ID, "--expect", item+"="+lrItoa(v)); err != nil {
		t.Fatal(err)
	}
}

func TestLinkJSON(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	out, _, err := lrRun(t, "", "--json", "link", "add", "alpha", "Docs", "https://example.com")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		ChangeID int64       `json:"change_id"`
		Link     *store.Link `json:"link"`
	}
	if err := json.Unmarshal([]byte(out), &v); err != nil || v.Link == nil || v.Link.Label != "Docs" || v.ChangeID == 0 {
		t.Fatalf("%v: %s", err, out)
	}
}

func TestLinkUnknownPlot(t *testing.T) {
	linkRepoEnv(t, store.PlotInput{})
	if _, _, err := lrRun(t, "", "link", "add", "nope", "a", "b"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("err %v", err)
	}
}
