package store_test

import (
	"errors"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestRulesOfAPlot(t *testing.T) {
	s := openStore(t)
	a, b := newPlot(t, s, "A"), newPlot(t, s, "B")
	r, err := s.AddRule(store.Rule{PlotID: a.ID, Name: " Views use the colour tokens ", Command: "scripts/check-colours.sh",
		Note: "Use LoamColor, not a literal colour."})
	if err != nil {
		t.Fatal(err)
	}
	if r.Name != "Views use the colour tokens" || r.Check() != (store.Check{Name: "Rule: Views use the colour tokens", Command: "scripts/check-colours.sh"}) {
		t.Fatalf("%+v", r)
	}
	if _, err := s.AddRule(store.Rule{PlotID: b.ID, Name: "No command"}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("a rule with no command: %v", err)
	}
	if list, _ := s.ListRules(b.ID); len(list) != 0 {
		t.Fatalf("plot B has %+v", list)
	}
	if list, _ := s.ListRules(a.ID); len(list) != 1 || list[0].Note != r.Note {
		t.Fatalf("%+v", list)
	}
	if err := s.RemoveRule(r.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetRule(r.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("got %v", err)
	}
}
