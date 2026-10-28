package store_test

import (
	"errors"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestRunDefaultsOfAPlot(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	if d, err := s.GetRunDefaults(p.ID); err != nil || d != (store.RunDefaults{PlotID: p.ID}) {
		t.Fatalf("new plot: %+v %v", d, err)
	}
	want := store.RunDefaults{PlotID: p.ID, Model: "opus", Effort: "xhigh"}
	if _, err := s.SetRunDefaults(want); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.GetRunDefaults(p.ID); d != want {
		t.Fatalf("got %+v", d)
	}
	// Setting again replaces the row.
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: p.ID}); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.GetRunDefaults(p.ID); d.Model != "" || d.Effort != "" {
		t.Fatalf("cleared: %+v", d)
	}
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: p.ID, Effort: "extreme"}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("bad effort: %v", err)
	}
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: "nosuchplot"}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("no plot: %v", err)
	}
}
