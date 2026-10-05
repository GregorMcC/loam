package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

// Shared helpers for the plot commands. Tickets 09 and 10 both use them, so
// they live here and not in a command file.

// ErrAmbiguous means a plot argument matches more than one plot.
var ErrAmbiguous = errors.New("ambiguous plot")

// openStore opens the store at LOAM_HOME or ~/.loam.
func openStore() (*store.Store, error) { return store.OpenHome() }

// loamBinary returns the path of the running loam binary with links resolved,
// for the hook command and the MCP server registration.
func loamBinary() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return exe, nil
}

// resolvePlot finds the plot that arg names. arg is an ID, an exact name, or
// a unique prefix of a name. Name matches ignore case. An exact ID wins, then
// an exact name, then a prefix.
func resolvePlot(s *store.Store, arg string) (store.PlotSummary, error) {
	plots, err := s.ListPlots()
	if err != nil {
		return store.PlotSummary{}, err
	}
	return matchPlot(plots, arg)
}

func matchPlot(plots []store.PlotSummary, arg string) (store.PlotSummary, error) {
	if arg == "" {
		return store.PlotSummary{}, fmt.Errorf("no plot given: %w", store.ErrInvalid)
	}
	for _, p := range plots {
		if p.ID == arg {
			return p, nil
		}
	}
	var exact, prefix []store.PlotSummary
	low := strings.ToLower(arg)
	for _, p := range plots {
		name := strings.ToLower(p.Name)
		switch {
		case name == low:
			exact = append(exact, p)
		case strings.HasPrefix(name, low):
			prefix = append(prefix, p)
		}
	}
	for _, set := range [][]store.PlotSummary{exact, prefix} {
		switch len(set) {
		case 0:
			continue
		case 1:
			return set[0], nil
		default:
			names := make([]string, len(set))
			for i, p := range set {
				names[i] = fmt.Sprintf("%s (%s)", p.Name, p.ID)
			}
			sort.Strings(names)
			return store.PlotSummary{}, fmt.Errorf("%q matches %s: %w", arg, strings.Join(names, ", "), ErrAmbiguous)
		}
	}
	return store.PlotSummary{}, unknownPlotError{arg}
}

// addExpectFlag adds the repeatable --expect <item>=<version> flag.
func addExpectFlag(c *cobra.Command, into *[]string) {
	c.Flags().StringArrayVar(into, "expect", nil,
		"fail if <item> changed since <version>, for example --expect where=41 (repeatable)")
}

// parseExpect turns --expect values into the map that store.Change takes.
// It returns nil for no values, so the write goes over the latest value.
func parseExpect(vals []string) (map[string]int64, error) {
	if len(vals) == 0 {
		return nil, nil
	}
	m := make(map[string]int64, len(vals))
	for _, v := range vals {
		item, num, ok := strings.Cut(v, "=")
		if !ok || item == "" {
			return nil, fmt.Errorf("--expect %q: use <item>=<version>: %w", v, store.ErrInvalid)
		}
		n, err := strconv.ParseInt(num, 10, 64)
		if err != nil || n < 0 {
			return nil, fmt.Errorf("--expect %q: the version is not a number: %w", v, store.ErrInvalid)
		}
		m[item] = n
	}
	return m, nil
}

// cliActor is the actor for a write from the CLI. The global --actor app flag
// makes it the app.
func cliActor(cmd *cobra.Command) store.Actor {
	if v, _ := cmd.Flags().GetString("actor"); v == string(store.ActorApp) {
		return store.Actor{Kind: store.ActorApp}
	}
	return store.Actor{Kind: store.ActorCLI}
}

// commit applies a change and rewrites the seed. A seed that fails to write
// is a warning (see [seed.AfterChange]).
func commit(s *store.Store, c store.Change) (*store.Result, error) {
	res, err := s.Apply(c)
	if err != nil {
		return nil, err
	}
	seed.AfterChange(s, res)
	return res, nil
}

// writeEdits resolves the plot, builds the edits from it, commits them, and
// prints the warnings. It returns the result, the edits, and the item that the
// write is about: the item it added, else the item of the first edit.
func writeEdits(cmd *cobra.Command, s *store.Store, plotArg string, expect map[string]int64, build func(*store.Plot) ([]store.Edit, error)) (*store.Result, []store.Edit, string, error) {
	sum, err := resolvePlot(s, plotArg)
	if err != nil {
		return nil, nil, "", err
	}
	p, err := s.GetPlot(sum.ID)
	if err != nil {
		return nil, nil, "", err
	}
	edits, err := build(&p)
	if err != nil {
		return nil, nil, "", err
	}
	res, err := commit(s, store.Change{PlotID: p.ID, Actor: cliActor(cmd), Expect: expect, Edits: edits})
	if err != nil {
		return nil, nil, "", err
	}
	printWarnings(cmd, res.Warnings)
	item := edits[0].Item
	if len(res.Added) > 0 {
		item = res.Added[0]
	}
	return res, edits, item, nil
}

// printJSON writes v as indented JSON to the command's output.
func printJSON(cmd *cobra.Command, v any) error {
	enc := json.NewEncoder(cmd.OutOrStdout())
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

// printWarnings writes each warning to stderr.
func printWarnings(cmd *cobra.Command, warnings []string) {
	for _, w := range warnings {
		fmt.Fprintln(cmd.ErrOrStderr(), "loam: warning:", w)
	}
}
