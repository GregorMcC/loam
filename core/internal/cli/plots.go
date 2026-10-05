package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/GregorMcC/loam/core/internal/editor"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newListCmd)
	Register(newShowCmd)
	Register(newNewCmd)
	Register(newEditCmd)
	Register(newSetCmd)
}

// briefHeads maps the editor file headings to store items, in file order.
var briefHeads = []struct{ head, item string }{
	{"# Name", store.ItemName},
	{"# What", store.ItemWhat},
	{"# Why", store.ItemWhy},
	{"# Where it stands", store.ItemWhere},
}

func plotValue(p store.Plot, item string) string {
	switch item {
	case store.ItemName:
		return p.Name
	case store.ItemWhat:
		return p.What
	case store.ItemWhy:
		return p.Why
	default:
		return p.Where
	}
}

// formatBrief renders the editor file. A new plot has no Name section.
func formatBrief(p store.Plot, withName bool) string {
	var b strings.Builder
	for _, h := range briefHeads {
		if h.item == store.ItemName && !withName {
			continue
		}
		fmt.Fprintf(&b, "%s\n%s\n\n", h.head, plotValue(p, h.item))
	}
	return b.String()
}

// parseBrief reads the editor file. It returns the text of each section that
// the file has. A section that the person deleted is absent from the map.
func parseBrief(text string) map[string]string {
	out := map[string]string{}
	cur := ""
	var buf []string
	flush := func() {
		if cur != "" {
			out[cur] = strings.TrimSpace(strings.Join(buf, "\n"))
		}
		buf = nil
	}
	for _, line := range strings.Split(text, "\n") {
		matched := false
		for _, h := range briefHeads {
			if strings.EqualFold(strings.TrimSpace(line), h.head) {
				flush()
				cur, matched = h.item, true
				break
			}
		}
		if !matched {
			buf = append(buf, line)
		}
	}
	flush()
	return out
}

// staleDetail adds the current values to a stale-write error.
func staleDetail(err error) error {
	var se *store.StaleError
	if !errors.As(err, &se) {
		return err
	}
	var parts []string
	for _, it := range se.Items {
		switch {
		case !it.Exists:
			parts = append(parts, fmt.Sprintf("%s is gone", it.Item))
		case it.Link != nil || it.Repo != nil:
			parts = append(parts, fmt.Sprintf("%s is now at version %d", it.Item, it.Current))
		default:
			parts = append(parts, fmt.Sprintf("%s is now at version %d: %q", it.Item, it.Current, it.Value))
		}
	}
	return fmt.Errorf("%w; %s", err, strings.Join(parts, "; "))
}

func plotArg(s *store.Store, arg string) (store.Plot, error) {
	ps, err := resolvePlot(s, arg)
	if err != nil {
		return store.Plot{}, err
	}
	return s.GetPlot(ps.ID)
}

func newListCmd() *cobra.Command {
	var archived bool
	c := &cobra.Command{
		Use:   "list",
		Short: "List the plots in their stored order",
		Long:  "List the plots in their stored order. Archived plots are not in the list. With --archived, the list holds only the archived plots.",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			all, err := s.ListPlots()
			if err != nil {
				return err
			}
			plots := store.FilterPlots(all, archived)
			if JSON(cmd) {
				return printJSON(cmd, plots)
			}
			for _, p := range plots {
				fmt.Fprintf(cmd.OutOrStdout(), "%s  %s", p.ID, p.Name)
				if what := firstLine(p.What); what != "" {
					fmt.Fprintf(cmd.OutOrStdout(), "  %s", what)
				}
				fmt.Fprintln(cmd.OutOrStdout())
			}
			return nil
		},
	}
	c.Flags().BoolVar(&archived, "archived", false, "list the archived plots, and no others")
	return c
}

func firstLine(s string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	return line
}

func newShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show <plot>",
		Short: "Show a plot in full",
		Long:  "Show a plot in full. <plot> is an ID, a name, or a unique prefix of a name. --json also prints the version of each item.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			p, err := plotArg(s, args[0])
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, newPlotOut(p, linkkind.Vaults()))
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%s (%s)\n", p.Name, p.ID)
			for _, sec := range []struct{ title, text string }{{"What", p.What}, {"Why", p.Why}, {"Where it stands", p.Where}} {
				if sec.text != "" {
					fmt.Fprintf(w, "\n%s\n%s\n", sec.title, sec.text)
				}
			}
			if len(p.Repos) > 0 {
				fmt.Fprintln(w, "\nRepos")
				for _, r := range p.Repos {
					mark := ""
					if r.Main {
						mark = " (main)"
					}
					fmt.Fprintf(w, "- %s%s %s\n", r.Path, mark, r.Note)
				}
			}
			if len(p.Links) > 0 {
				fmt.Fprintln(w, "\nLinks")
				for _, l := range p.Links {
					fmt.Fprintf(w, "- %s: %s %s\n", l.Label, l.Target, l.Note)
				}
			}
			return nil
		},
	}
}

func newNewCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "new <name>",
		Short: "Create a plot and open its brief in the editor",
		Long: "Create a plot and open its brief in $VISUAL or $EDITOR (then vi). The editor must wait until you close the file, for example \"code --wait\".\n" +
			"With --json, the command skips the editor and prints the new plot.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			in := store.PlotInput{Name: args[0]}
			if !JSON(cmd) {
				text, err := editor.Edit(formatBrief(store.Plot{}, false))
				if err != nil {
					return err
				}
				parts := parseBrief(text)
				in.What, in.Why, in.Where = parts[store.ItemWhat], parts[store.ItemWhy], parts[store.ItemWhere]
			}
			res, err := s.CreatePlot(in, cliActor(cmd))
			if err != nil {
				return err
			}
			seed.AfterChange(s, res)
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, newPlotOut(res.Plot, linkkind.Vaults()))
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Created %s (%s)\n", res.Plot.Name, res.Plot.ID)
			return nil
		},
	}
}

func newEditCmd() *cobra.Command {
	var expect []string
	c := &cobra.Command{
		Use:   "edit <plot>",
		Short: "Edit the name and the brief in the editor",
		Long: "Open the name and the brief in $VISUAL or $EDITOR (then vi). The save makes one change.\n" +
			"If another write changed an item while you edited, the editor opens again with the current text.\n" +
			"Your own text goes to a temp file, and the command prints its path.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			userExpect, err := parseExpect(expect)
			if err != nil {
				return err
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			cur, err := plotArg(s, args[0])
			if err != nil {
				return err
			}
			for {
				text, err := editor.Edit(formatBrief(cur, true))
				if err != nil {
					return err
				}
				parts := parseBrief(text)
				c := store.Change{PlotID: cur.ID, Actor: cliActor(cmd), Expect: map[string]int64{}}
				for _, h := range briefHeads {
					v, ok := parts[h.item]
					if !ok || v == strings.TrimSpace(plotValue(cur, h.item)) {
						continue
					}
					c.Edits = append(c.Edits, store.Edit{Op: store.OpSet, Item: h.item, Value: v})
					c.Expect[h.item] = cur.Versions[h.item]
				}
				if len(c.Edits) == 0 {
					if JSON(cmd) {
						return printJSON(cmd, newPlotOut(cur, linkkind.Vaults()))
					}
					fmt.Fprintln(cmd.ErrOrStderr(), "No change.")
					return nil
				}
				for k, v := range userExpect {
					c.Expect[k] = v
				}
				res, err := commit(s, c)
				var se *store.StaleError
				if errors.As(err, &se) {
					if len(userExpect) > 0 {
						return staleDetail(err)
					}
					kept, kerr := keepText(text)
					if kerr != nil {
						return kerr
					}
					fmt.Fprintf(cmd.ErrOrStderr(), "loam: %v. Your text is in %s. The editor opens again with the current text.\n", err, kept)
					if cur, err = s.GetPlot(cur.ID); err != nil {
						return err
					}
					continue
				}
				if err != nil {
					if kept, kerr := keepText(text); kerr == nil {
						fmt.Fprintf(cmd.ErrOrStderr(), "loam: your text is in %s\n", kept)
					}
					return err
				}
				printWarnings(cmd, res.Warnings)
				if JSON(cmd) {
					return printJSON(cmd, newPlotOut(res.Plot, linkkind.Vaults()))
				}
				fmt.Fprintf(cmd.OutOrStdout(), "Saved %s\n", res.Plot.Name)
				return nil
			}
		},
	}
	addExpectFlag(c, &expect)
	return c
}

func keepText(text string) (string, error) {
	f, err := os.CreateTemp("", "loam-kept-*.md")
	if err != nil {
		return "", err
	}
	defer f.Close()
	_, err = f.WriteString(text)
	return f.Name(), err
}

// fieldItems maps the field names of loam set to store items.
var fieldItems = map[string]string{
	"name":            store.ItemName,
	"what":            store.ItemWhat,
	"why":             store.ItemWhy,
	"where-it-stands": store.ItemWhere,
}

func newSetCmd() *cobra.Command {
	var expect []string
	c := &cobra.Command{
		Use:   "set <plot> <field> <text|->",
		Short: "Set the name, what, why, or where-it-stands of a plot",
		Long:  "Set one field of a plot. The fields are name, what, why, and where-it-stands. A text of - reads stdin.",
		Args:  cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			item, ok := fieldItems[args[1]]
			if !ok {
				return fmt.Errorf("unknown field %q: use name, what, why, or where-it-stands: %w", args[1], store.ErrInvalid)
			}
			exp, err := parseExpect(expect)
			if err != nil {
				return err
			}
			text := args[2]
			if text == "-" {
				b, err := io.ReadAll(cmd.InOrStdin())
				if err != nil {
					return err
				}
				text = strings.TrimRight(string(b), "\n")
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			ps, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			res, err := commit(s, store.Change{
				PlotID: ps.ID, Actor: cliActor(cmd), Expect: exp,
				Edits: []store.Edit{{Op: store.OpSet, Item: item, Value: text}},
			})
			if err != nil {
				return staleDetail(err)
			}
			printWarnings(cmd, res.Warnings)
			if JSON(cmd) {
				return printJSON(cmd, newPlotOut(res.Plot, linkkind.Vaults()))
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Set %s of %s\n", args[1], res.Plot.Name)
			return nil
		},
	}
	addExpectFlag(c, &expect)
	return c
}
