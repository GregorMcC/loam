package store_test

import (
	"errors"
	"fmt"
	"slices"
	"strings"
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

// labels returns the link labels of a plot in order.
func labels(t *testing.T, s *store.Store, plotID string) []string {
	t.Helper()
	p, err := s.GetPlot(plotID)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, l := range p.Links {
		out = append(out, l.Label)
	}
	return out
}

func positions(t *testing.T, s *store.Store, plotID string) []int {
	t.Helper()
	p, err := s.GetPlot(plotID)
	if err != nil {
		t.Fatal(err)
	}
	var out []int
	for _, l := range p.Links {
		out = append(out, l.Position)
	}
	return out
}

// linkIDs returns the link IDs of a plot in order, comma-joined.
func linkIDs(t *testing.T, s *store.Store, plotID string) string {
	t.Helper()
	p, err := s.GetPlot(plotID)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, l := range p.Links {
		ids = append(ids, l.ID)
	}
	return strings.Join(ids, ",")
}

// addLinks adds one link per label and returns the item of each label.
func addLinks(t *testing.T, s *store.Store, plotID string, names ...string) map[string]string {
	t.Helper()
	items := map[string]string{}
	for _, n := range names {
		r := apply(t, s, store.Change{PlotID: plotID, Edits: []store.Edit{{Op: store.OpAddLink, Label: store.S(n), Target: store.S("https://" + n)}}})
		items[n] = r.Added[0]
	}
	return items
}

func moveLink(plotID, item string, pos int) store.Change {
	return store.Change{PlotID: plotID, Edits: []store.Edit{{Op: store.OpMoveLink, Item: item, Value: fmt.Sprint(pos)}}}
}

func TestMoveLink(t *testing.T) {
	cases := []struct {
		name string
		move string
		pos  int
		want []string
	}{
		{"to the start", "d", 1, []string{"d", "a", "b", "c"}},
		{"to the end", "a", 4, []string{"b", "c", "d", "a"}},
		{"to the middle", "d", 2, []string{"a", "d", "b", "c"}},
		{"same place", "b", 2, []string{"a", "b", "c", "d"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := openStore(t)
			p := newPlot(t, s, "p")
			items := addLinks(t, s, p.ID, "a", "b", "c", "d")
			before, err := s.GetPlot(p.ID)
			if err != nil {
				t.Fatal(err)
			}
			oldIDs := linkIDs(t, s, p.ID)
			r := apply(t, s, moveLink(p.ID, items[c.move], c.pos))
			if got := labels(t, s, p.ID); !slices.Equal(got, c.want) {
				t.Fatalf("order %v, want %v", got, c.want)
			}
			if slices.Equal(c.want, []string{"a", "b", "c", "d"}) {
				if r.ChangeID != 0 {
					t.Fatalf("a move to the same place wrote change %d", r.ChangeID)
				}
				return
			}
			if got := positions(t, s, p.ID); !slices.Equal(got, []int{1, 2, 3, 4}) {
				t.Fatalf("positions %v", got)
			}
			ch, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
			if err != nil {
				t.Fatal(err)
			}
			want := []store.Entry{{Item: store.ItemLinkOrder, Field: "order", Old: store.S(oldIDs), New: store.S(linkIDs(t, s, p.ID))}}
			if ch[0].ID != r.ChangeID || !entriesEqual(ch[0].Entries, want) {
				t.Fatalf("entries %+v", ch[0].Entries)
			}
			if r.Plot.Versions[store.ItemLinkOrder] != r.ChangeID {
				t.Fatalf("links version %d, want %d", r.Plot.Versions[store.ItemLinkOrder], r.ChangeID)
			}
			for _, item := range items {
				if r.Plot.Versions[item] != before.Versions[item] {
					t.Errorf("%s version %d, was %d", item, r.Plot.Versions[item], before.Versions[item])
				}
			}
		})
	}
}

func entriesEqual(a, b []store.Entry) bool {
	return slices.EqualFunc(a, b, func(x, y store.Entry) bool {
		return x.Item == y.Item && x.Field == y.Field && *x.Old == *y.Old && *x.New == *y.New
	})
}

func TestLinkOrderVersionBeforeAnyMove(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	got, err := s.GetPlot(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if v, ok := got.Versions[store.ItemLinkOrder]; !ok || v != 0 {
		t.Fatalf("links version %d, present %v", v, ok)
	}
}

func TestMoveLinkRejectsBadInput(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c", "d")
	for _, pos := range []int{0, 5} {
		_, err := s.Apply(moveLink(p.ID, items["a"], pos))
		if !errors.Is(err, store.ErrInvalid) || !strings.Contains(err.Error(), "choose a number from 1 to 4") {
			t.Errorf("position %d: %v", pos, err)
		}
	}
	if _, err := s.Apply(moveLink(p.ID, store.LinkItem("nope"), 1)); !errors.Is(err, store.ErrNotFound) {
		t.Errorf("unknown link: %v", err)
	}
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"a", "b", "c", "d"}) {
		t.Errorf("order changed: %v", got)
	}
}

func TestMoveLinkClosesGaps(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: items["b"]}}})
	d := addLinks(t, s, p.ID, "d")["d"]
	apply(t, s, moveLink(p.ID, d, 1))
	if got := positions(t, s, p.ID); !slices.Equal(got, []int{1, 2, 3}) {
		t.Fatalf("positions %v", got)
	}
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"d", "a", "c"}) {
		t.Fatalf("order %v", got)
	}
}

func TestUndoEarlierLinkEditAfterMove(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	edit := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpUpdateLink, Item: items["a"], Label: store.S("a2")}}})
	apply(t, s, moveLink(p.ID, items["c"], 1))
	r, err := s.Undo(edit.ChangeID, app, false)
	var clash *store.UndoClashError
	if errors.As(err, &clash) {
		t.Fatalf("clash: %v", err)
	}
	if err != nil {
		t.Fatal(err)
	}
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"c", "a", "b"}) || r.ChangeID == 0 {
		t.Fatalf("labels %v, change %d", got, r.ChangeID)
	}
}

func TestUndoMoveRestoresOrder(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	mv := apply(t, s, moveLink(p.ID, items["c"], 1))
	u := undo(t, s, mv.ChangeID, false)
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"a", "b", "c"}) {
		t.Fatalf("order %v", got)
	}
	if got := positions(t, s, p.ID); !slices.Equal(got, []int{1, 2, 3}) {
		t.Fatalf("positions %v", got)
	}
	ch, err := s.ListChanges(store.ChangeQuery{PlotID: p.ID, Newest: true, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if ch[0].ID != u.ChangeID || len(ch[0].Entries) != 1 || ch[0].Entries[0].Item != store.ItemLinkOrder || ch[0].Entries[0].Field != "order" {
		t.Fatalf("undo entries %+v", ch[0].Entries)
	}
}

func TestUndoMoveAfterAddAndRemove(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	mv := apply(t, s, moveLink(p.ID, items["c"], 1))
	apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: items["a"]}}})
	addLinks(t, s, p.ID, "d")
	undo(t, s, mv.ChangeID, false)
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"b", "c", "d"}) {
		t.Fatalf("order %v", got)
	}
	if got := positions(t, s, p.ID); !slices.Equal(got, []int{1, 2, 3}) {
		t.Fatalf("positions %v", got)
	}
}

func TestUndoRemoveAfterMoveKeepsPositionsUnique(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	rm := apply(t, s, store.Change{PlotID: p.ID, Edits: []store.Edit{{Op: store.OpRemoveLink, Item: items["a"]}}})
	apply(t, s, moveLink(p.ID, items["c"], 1))
	undo(t, s, rm.ChangeID, false)
	if got := labels(t, s, p.ID); !slices.Equal(got, []string{"a", "c", "b"}) {
		t.Fatalf("order %v", got)
	}
	if got := positions(t, s, p.ID); !slices.Equal(got, []int{1, 2, 3}) {
		t.Fatalf("positions %v", got)
	}
}

func TestMoveLinkStale(t *testing.T) {
	s := openStore(t)
	p := newPlot(t, s, "p")
	items := addLinks(t, s, p.ID, "a", "b", "c")
	got, err := s.GetPlot(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	old := got.Versions[store.ItemLinkOrder]
	apply(t, s, moveLink(p.ID, items["c"], 1))
	c := moveLink(p.ID, items["a"], 1)
	c.Expect = map[string]int64{store.ItemLinkOrder: old}
	_, err = s.Apply(c)
	var stale *store.StaleError
	if !errors.As(err, &stale) {
		t.Fatalf("want a stale error, got %v", err)
	}
	if stale.Items[0].Value != linkIDs(t, s, p.ID) {
		t.Fatalf("stale value %q", stale.Items[0].Value)
	}
}
