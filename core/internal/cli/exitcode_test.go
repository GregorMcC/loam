package cli

import (
	"errors"
	"fmt"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestClassify(t *testing.T) {
	stale := &store.StaleError{PlotID: "p1", Items: []store.StaleItem{{Item: "what", Expected: 1, Current: 2, Exists: true, Value: "x"}}}
	cases := []struct {
		name string
		err  error
		code int
		kind string
	}{
		{"general", errors.New("boom"), 1, "error"},
		{"invalid", fmt.Errorf("bad: %w", store.ErrInvalid), 2, "invalid"},
		{"stale", fmt.Errorf("wrapped: %w", stale), 10, "stale"},
		{"undo clash", fmt.Errorf("x: %w", ErrUndoClash), 11, "undo_clash"},
		{"link path", fmt.Errorf("x: %w", ErrLinkPathMissing), 12, "link_path_missing"},
		{"contract", fmt.Errorf("x: %w", ErrContractMismatch), 13, "contract_mismatch"},
		{"unknown plot", fmt.Errorf("x: %w", ErrUnknownPlot), 14, "unknown_plot"},
		{"ambiguous", fmt.Errorf("x: %w", ErrAmbiguous), 15, "ambiguous"},
		{"not found", fmt.Errorf("x: %w", store.ErrNotFound), 1, "error"},
	}
	for _, c := range cases {
		got := classify(c.err)
		if got.ExitCode != c.code || got.Kind != c.kind {
			t.Errorf("%s: got %d %s, want %d %s", c.name, got.ExitCode, got.Kind, c.code, c.kind)
		}
		if got.Message == "" {
			t.Errorf("%s: empty message", c.name)
		}
	}
}

func TestClassifyStaleCarriesItems(t *testing.T) {
	stale := &store.StaleError{PlotID: "p1", Items: []store.StaleItem{{Item: "what", Current: 2, Exists: true, Value: "x"}}}
	got := classify(stale)
	d, ok := got.Details.(*store.StaleError)
	if !ok || d.PlotID != "p1" || len(d.Items) != 1 {
		t.Fatalf("details %#v", got.Details)
	}
}

type detailed struct{}

func (detailed) Error() string     { return "d" }
func (detailed) ErrorDetails() any { return map[string]int{"n": 1} }
func (detailed) Is(t error) bool   { return t == ErrUndoClash }

func TestClassifyUsesErrorDetails(t *testing.T) {
	got := classify(fmt.Errorf("w: %w", detailed{}))
	if got.Kind != "undo_clash" || got.Details == nil {
		t.Fatalf("%#v", got)
	}
}
