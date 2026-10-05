package cli

import (
	"fmt"
	"strings"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newLinkCmd)
}

func newLinkCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "link",
		Short: "Add, edit, or remove a link of a plot",
		Args:  cobra.NoArgs,
		RunE:  func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newLinkAddCmd(), newLinkEditCmd(), newLinkRmCmd())
	return c
}

func newLinkAddCmd() *cobra.Command {
	var note string
	var expect []string
	c := &cobra.Command{
		Use:   "add <plot> [<label>] <target>",
		Short: "Add a link to a plot",
		Long: "Add a link to a plot. The target is a URL or a local path.\n" +
			"With no label, the link takes one from the target: the file name, the issue ID, or the page title.",
		Args: cobra.RangeArgs(2, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			label, target := "", args[len(args)-1]
			if len(args) == 3 {
				label = args[1]
			}
			return writeLink(cmd, args[0], expect, func(*store.Plot) ([]store.Edit, error) {
				return []store.Edit{{Op: store.OpAddLink, Label: store.S(label), Target: store.S(target), Note: store.S(note)}}, nil
			})
		},
	}
	c.Flags().StringVar(&note, "note", "", "a note for the link")
	addExpectFlag(c, &expect)
	return c
}

func newLinkEditCmd() *cobra.Command {
	var label, target, note string
	var expect []string
	c := &cobra.Command{
		Use:   "edit <plot> <link>",
		Short: "Change the label, target, or note of a link",
		Long:  "Change a link. <link> is a link ID or an exact label. Only the flags you give change.",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			f := cmd.Flags()
			if !f.Changed("label") && !f.Changed("target") && !f.Changed("note") {
				return fmt.Errorf("give at least one of --label, --target, --note: %w", store.ErrInvalid)
			}
			return writeLink(cmd, args[0], expect, func(p *store.Plot) ([]store.Edit, error) {
				l, err := findLink(p, args[1])
				if err != nil {
					return nil, err
				}
				e := store.Edit{Op: store.OpUpdateLink, Item: store.LinkItem(l.ID)}
				if f.Changed("label") {
					e.Label = store.S(label)
				}
				if f.Changed("target") {
					e.Target = store.S(target)
				}
				if f.Changed("note") {
					e.Note = store.S(note)
				}
				return []store.Edit{e}, nil
			})
		},
	}
	c.Flags().StringVar(&label, "label", "", "the new label")
	c.Flags().StringVar(&target, "target", "", "the new target")
	c.Flags().StringVar(&note, "note", "", "the new note")
	addExpectFlag(c, &expect)
	return c
}

func newLinkRmCmd() *cobra.Command {
	var expect []string
	c := &cobra.Command{
		Use:   "rm <plot> <link>",
		Short: "Remove a link from a plot",
		Long:  "Remove a link. <link> is a link ID or an exact label.",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return writeLink(cmd, args[0], expect, func(p *store.Plot) ([]store.Edit, error) {
				l, err := findLink(p, args[1])
				if err != nil {
					return nil, err
				}
				return []store.Edit{{Op: store.OpRemoveLink, Item: store.LinkItem(l.ID)}}, nil
			})
		},
	}
	addExpectFlag(c, &expect)
	return c
}

// findLink finds a link by ID or by exact label.
func findLink(p *store.Plot, arg string) (store.Link, error) {
	for _, l := range p.Links {
		if l.ID == arg {
			return l, nil
		}
	}
	var hits []store.Link
	for _, l := range p.Links {
		if l.Label == arg {
			hits = append(hits, l)
		}
	}
	switch len(hits) {
	case 0:
		return store.Link{}, fmt.Errorf("no link %q in plot %s: %w", arg, p.Name, store.ErrNotFound)
	case 1:
		return hits[0], nil
	}
	ids := make([]string, len(hits))
	for i, l := range hits {
		ids[i] = l.ID
	}
	return store.Link{}, fmt.Errorf("%d links have the label %q (%s): use a link ID: %w", len(hits), arg, strings.Join(ids, ", "), ErrAmbiguous)
}

// writeLink resolves the plot, builds the edits, commits them, and prints the result.
func writeLink(cmd *cobra.Command, plotArg string, expectVals []string, build func(*store.Plot) ([]store.Edit, error)) error {
	expect, err := parseExpect(expectVals)
	if err != nil {
		return err
	}
	s, err := openStore()
	if err != nil {
		return err
	}
	defer s.Close()
	res, edits, item, err := writeEdits(cmd, s, plotArg, expect, build)
	if err != nil {
		return err
	}
	var link *store.Link
	for i := range res.Plot.Links {
		if store.LinkItem(res.Plot.Links[i].ID) == item {
			link = &res.Plot.Links[i]
		}
	}
	if JSON(cmd) {
		return printJSON(cmd, struct {
			ChangeID int64       `json:"change_id"`
			Plot     string      `json:"plot"`
			Link     *store.Link `json:"link,omitempty"`
		}{res.ChangeID, res.Plot.ID, link})
	}
	out := cmd.OutOrStdout()
	switch {
	case res.ChangeID == 0:
		fmt.Fprintln(out, "No change.")
	case edits[0].Op == store.OpRemoveLink:
		fmt.Fprintln(out, "Removed the link.")
	case link != nil:
		fmt.Fprintf(out, "Link %s: %s -> %s\n", link.ID, link.Label, link.Target)
	}
	return nil
}
