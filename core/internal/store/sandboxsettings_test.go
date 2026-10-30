package store_test

import (
	"errors"
	"os"
	"reflect"
	"sync"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// TAS-175: the paths and hosts that the user adds to the sandbox of a run.
// An empty PlotID is the machine scope, which holds for every plot.
func TestSandboxSettingsOfAPlotAndOfTheMachine(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	empty := func(plotID string) store.SandboxSettings {
		return store.SandboxSettings{PlotID: plotID, Read: []string{}, Write: []string{}, Hosts: []string{}}
	}
	for _, id := range []string{"", p.ID} {
		if got, err := s.GetSandboxSettings(id); err != nil || !reflect.DeepEqual(got, empty(id)) {
			t.Fatalf("new store, scope %q: %+v %v", id, got, err)
		}
	}
	home, _ := os.UserHomeDir()

	// Loam trims, cleans, lowers hosts, and leaves out empty items and repeats.
	set := store.SandboxSettings{
		PlotID: p.ID,
		Read:   []string{" ~/notes/ ", "", "~/notes", home + "/specs"},
		Write:  []string{"/opt/out"},
		Hosts:  []string{"Registry.Example.com", "registry.example.com", " "},
	}
	want := store.SandboxSettings{PlotID: p.ID, Read: []string{"~/notes", "~/specs"}, Write: []string{"/opt/out"}, Hosts: []string{"registry.example.com"}}
	if got, err := s.SetSandboxSettings(set); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("set %+v %v", got, err)
	}
	if got, _ := s.GetSandboxSettings(p.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
	// The scopes are separate.
	if got, _ := s.GetSandboxSettings(""); !reflect.DeepEqual(got, empty("")) {
		t.Fatalf("machine scope %+v", got)
	}
	machine := store.SandboxSettings{Read: []string{"~/.nvm"}, Write: []string{}, Hosts: []string{"*.example.org"}}
	if got, err := s.SetSandboxSettings(machine); err != nil || !reflect.DeepEqual(got, machine) {
		t.Fatalf("machine %+v %v", got, err)
	}
	if got, _ := s.GetSandboxSettings(p.ID); !reflect.DeepEqual(got, want) {
		t.Fatalf("plot scope after the machine set: %+v", got)
	}
	// Setting again replaces the row.
	if _, err := s.SetSandboxSettings(store.SandboxSettings{PlotID: p.ID}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetSandboxSettings(p.ID); !reflect.DeepEqual(got, empty(p.ID)) {
		t.Fatalf("cleared %+v", got)
	}
}

func TestSandboxSettingsRefuseWhatOpensHome(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	for name, set := range map[string]store.SandboxSettings{
		"home":           {PlotID: p.ID, Read: []string{"~"}},
		"root":           {Write: []string{"/"}},
		"credentials":    {PlotID: p.ID, Write: []string{"~/.ssh"}},
		"relative":       {Read: []string{"notes"}},
		"all hosts":      {Hosts: []string{"*"}},
		"url":            {PlotID: p.ID, Hosts: []string{"https://example.com"}},
		"one good, one":  {Read: []string{"~/ok", "~/.aws/x"}},
		"no such plot":   {PlotID: "nosuchplot", Read: []string{"~/ok"}},
		"wildcard path":  {Read: []string{"~/*"}},
		"top level host": {Hosts: []string{"*.com"}},
	} {
		err := func() error { _, err := s.SetSandboxSettings(set); return err }()
		want := store.ErrInvalid
		if name == "no such plot" {
			want = store.ErrNotFound
		}
		if !errors.Is(err, want) {
			t.Errorf("%s: %v, want %v", name, err, want)
		}
	}
	// A refused set stores nothing.
	if got, _ := s.GetSandboxSettings(""); len(got.Read)+len(got.Write)+len(got.Hosts) != 0 {
		t.Fatalf("stored %+v", got)
	}
}

func TestDeletingAPlotDeletesItsSandboxSettings(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "A")
	if _, err := s.SetSandboxSettings(store.SandboxSettings{PlotID: p.ID, Hosts: []string{"example.com"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetSandboxSettings(store.SandboxSettings{Hosts: []string{"example.org"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetArchived(p.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeletePlot(p.ID); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetSandboxSettings(p.ID); len(got.Hosts) != 0 {
		t.Fatalf("plot scope %+v", got)
	}
	if got, _ := s.GetSandboxSettings(""); len(got.Hosts) != 1 {
		t.Fatalf("machine scope %+v", got)
	}
}

// TAS-189: an update changes only the lists that it names, in one write, so
// two updates of different lists both stay.
func TestUpdateSandboxSettingsKeepsTheListsThatItDoesNotName(t *testing.T) {
	s := openStore(t)
	if _, err := s.SetSandboxSettings(store.SandboxSettings{Read: []string{"~/a"}, Write: []string{"~/w"}, Hosts: []string{"a.example.com", "b.example.com"}}); err != nil {
		t.Fatal(err)
	}
	// Many rounds of two updates at once, so a read-then-write race would show.
	for round := 0; round < 25; round++ {
		var wg sync.WaitGroup
		for _, c := range []store.SandboxChange{
			{Hosts: &[]string{"a.example.com"}},
			{Read: &[]string{"~/a", "~/b"}},
		} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if _, err := s.UpdateSandboxSettings("", c); err != nil {
					t.Error(err)
				}
			}()
		}
		wg.Wait()
	}
	want := store.SandboxSettings{Read: []string{"~/a", "~/b"}, Write: []string{"~/w"}, Hosts: []string{"a.example.com"}}
	if got, err := s.GetSandboxSettings(""); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v %v, want %+v", got, err, want)
	}
	// An update that names no list changes nothing.
	if got, err := s.UpdateSandboxSettings("", store.SandboxChange{}); err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("empty update: %+v %v", got, err)
	}
	if _, err := s.UpdateSandboxSettings("nosuchplot", store.SandboxChange{Hosts: &[]string{"c.example.com"}}); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("no plot: %v", err)
	}
	if _, err := s.UpdateSandboxSettings("", store.SandboxChange{Hosts: &[]string{"*"}}); !errors.Is(err, store.ErrInvalid) {
		t.Fatalf("bad host: %v", err)
	}
}
