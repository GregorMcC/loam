package store_test

import (
	"errors"
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func order(t *testing.T, s *store.Store) []string {
	t.Helper()
	ps, err := s.ListPlots()
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, p := range ps {
		names = append(names, p.Name)
	}
	return names
}

func TestMovePlot(t *testing.T) {
	cases := []struct {
		name string
		move string
		pos  int
		want []string
	}{
		{"to the start", "d", 1, []string{"d", "a", "b", "c"}},
		{"to the end", "a", 4, []string{"b", "c", "d", "a"}},
		{"to the middle", "d", 2, []string{"a", "d", "b", "c"}},
		{"down the list", "a", 3, []string{"b", "c", "a", "d"}},
		{"same place", "b", 2, []string{"a", "b", "c", "d"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := openStore(t)
			ids := map[string]string{}
			for _, n := range []string{"a", "b", "c", "d"} {
				ids[n] = newPlot(t, s, n).ID
			}
			if err := s.MovePlot(ids[c.move], c.pos); err != nil {
				t.Fatal(err)
			}
			if got := order(t, s); !slices.Equal(got, c.want) {
				t.Fatalf("order %v, want %v", got, c.want)
			}
			ch, err := s.ListChanges(store.ChangeQuery{})
			if err != nil || len(ch) != 4 {
				t.Fatalf("changes %d (err %v), want only the 4 creates", len(ch), err)
			}
		})
	}
}

func TestMovePlotRejectsBadInput(t *testing.T) {
	s := openStore(t)
	a := newPlot(t, s, "a")
	newPlot(t, s, "b")
	for _, pos := range []int{0, -1, 3} {
		if err := s.MovePlot(a.ID, pos); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("position %d: %v", pos, err)
		}
	}
	if err := s.MovePlot("nope", 1); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown plot: %v", err)
	}
	if got := order(t, s); !slices.Equal(got, []string{"a", "b"}) {
		t.Errorf("order changed: %v", got)
	}
}
