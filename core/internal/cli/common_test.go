package cli

import (
	"errors"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestMatchPlot(t *testing.T) {
	plots := []store.PlotSummary{
		{ID: "aaaaaaaaaa", Name: "Loam v1"},
		{ID: "bbbbbbbbbb", Name: "Loam docs"},
		{ID: "cccccccccc", Name: "Reporting"},
		{ID: "dddddddddd", Name: "loam"},
	}
	cases := []struct {
		arg     string
		want    string
		wantErr error
	}{
		{"bbbbbbbbbb", "bbbbbbbbbb", nil},
		{"Reporting", "cccccccccc", nil},
		{"rep", "cccccccccc", nil},
		{"LOAM", "dddddddddd", nil}, // an exact name beats a prefix
		{"loam v", "aaaaaaaaaa", nil},
		{"loam ", "", ErrAmbiguous},
		{"zzz", "", store.ErrNotFound},
		{"", "", store.ErrInvalid},
	}
	for _, c := range cases {
		got, err := matchPlot(plots, c.arg)
		if c.wantErr != nil {
			if !errors.Is(err, c.wantErr) {
				t.Errorf("%q: err %v, want %v", c.arg, err, c.wantErr)
			}
			continue
		}
		if err != nil || got.ID != c.want {
			t.Errorf("%q: got %q, %v; want %q", c.arg, got.ID, err, c.want)
		}
	}
}

func TestParseExpect(t *testing.T) {
	m, err := parseExpect([]string{"where=41", "link:abc=7"})
	if err != nil || m["where"] != 41 || m["link:abc"] != 7 {
		t.Fatalf("got %v, %v", m, err)
	}
	if m, err := parseExpect(nil); m != nil || err != nil {
		t.Fatalf("empty: got %v, %v", m, err)
	}
	for _, bad := range []string{"where", "=4", "where=x", "where=-1"} {
		if _, err := parseExpect([]string{bad}); !errors.Is(err, store.ErrInvalid) {
			t.Errorf("%q: err %v", bad, err)
		}
	}
}
