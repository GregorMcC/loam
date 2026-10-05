package store_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func openStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(testutil.Home(t))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func newPlot(t *testing.T, s *store.Store, name string) store.Plot {
	t.Helper()
	res, err := s.CreatePlot(store.PlotInput{Name: name, What: "what " + name, Why: "why " + name}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	return res.Plot
}

func TestCreateAndGetPlot(t *testing.T) {
	s := openStore(t)
	res, err := s.CreatePlot(store.PlotInput{Name: "Loam", What: "a tool", Why: "focus"}, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.GetPlot(res.Plot.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.ID) != 10 {
		t.Fatalf("ID %q is not 10 characters", p.ID)
	}
	if p.Name != "Loam" || p.What != "a tool" || p.Why != "focus" || p.Where != "" {
		t.Fatalf("unexpected plot %+v", p)
	}
	if res.ChangeID == 0 || p.Revision != res.ChangeID {
		t.Fatalf("revision %d, change %d", p.Revision, res.ChangeID)
	}
	for _, item := range []string{"name", "what", "why", "where"} {
		if p.Versions[item] != res.ChangeID {
			t.Fatalf("version of %s is %d, want %d", item, p.Versions[item], res.ChangeID)
		}
	}
	if _, err := s.GetPlot("nosuchplot"); err == nil {
		t.Fatal("want not found")
	}
}

func TestOpenMakesTheHomeFolderPrivate(t *testing.T) {
	home := filepath.Join(t.TempDir(), "loam")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := store.Open(home)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	fi, err := os.Stat(home)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o700 {
		t.Fatalf("mode %v, want 0700", fi.Mode().Perm())
	}
}
