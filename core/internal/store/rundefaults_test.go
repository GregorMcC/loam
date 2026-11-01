package store_test

import (
	"errors"
	"reflect"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestRunDefaultsOfAPlot(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	if d, err := s.GetRunDefaults(p.ID); err != nil || !reflect.DeepEqual(d, store.RunDefaults{PlotID: p.ID, MCPServers: []string{}, Review: true, Checks: []store.Check{}}) {
		t.Fatalf("new plot: %+v %v", d, err)
	}
	want := store.RunDefaults{PlotID: p.ID, Model: "opus", Effort: "xhigh", MCPServers: []string{"loam", "linear-server"}, Review: false, ReviewEffort: "low", Checks: []store.Check{{Name: "Tests", Command: "go test"}}}
	// Loam trims each server name and leaves out empty names and repeats.
	set := want
	set.MCPServers = []string{" loam", "", "linear-server ", "loam"}
	if d, err := s.SetRunDefaults(set); err != nil || !reflect.DeepEqual(d, want) {
		t.Fatalf("set %+v %v", d, err)
	}
	if d, _ := s.GetRunDefaults(p.ID); !reflect.DeepEqual(d, want) {
		t.Fatalf("got %+v", d)
	}
	// Setting again replaces the row.
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: p.ID}); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.GetRunDefaults(p.ID); d.Model != "" || d.Effort != "" || d.MCPServers == nil || len(d.MCPServers) != 0 {
		t.Fatalf("cleared: %+v", d)
	}
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: p.ID, Effort: "extreme"}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("bad effort: %v", err)
	}
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: p.ID, ReviewEffort: "extreme"}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("bad review effort: %v", err)
	}
	if _, err := s.SetRunDefaults(store.RunDefaults{PlotID: "nosuchplot"}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("no plot: %v", err)
	}
}
