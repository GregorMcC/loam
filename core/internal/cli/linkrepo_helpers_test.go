package cli

import (
	"bytes"
	"strconv"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

func lrItoa(n int64) string { return strconv.FormatInt(n, 10) }

// linkRepoEnv makes a temp store with one plot and returns the store and plot.
func linkRepoEnv(t *testing.T, in store.PlotInput) (*store.Store, store.Plot) {
	t.Helper()
	testutil.Home(t)
	s, err := store.OpenHome()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if in.Name == "" {
		in.Name = "Alpha"
	}
	res, err := s.CreatePlot(in, store.Actor{Kind: store.ActorCLI})
	if err != nil {
		t.Fatal(err)
	}
	return s, res.Plot
}

// runCLI runs the loam root command in process.
func lrRun(t *testing.T, stdin string, args ...string) (out, errOut string, err error) {
	t.Helper()
	root := NewRootCmd()
	var o, e bytes.Buffer
	root.SetOut(&o)
	root.SetErr(&e)
	root.SetIn(strings.NewReader(stdin))
	root.SetArgs(args)
	err = root.Execute()
	return o.String(), e.String(), err
}

func lrPlot(t *testing.T, s *store.Store, id string) store.Plot {
	t.Helper()
	p, err := s.GetPlot(id)
	if err != nil {
		t.Fatal(err)
	}
	return p
}
