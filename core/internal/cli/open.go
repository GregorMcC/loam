package cli

import (
	"errors"
	"fmt"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newOpenCmd)
}

// linkOut is a link in a plot object. It adds what the core knows about the
// target: its kind, and for a local link whether the path exists.
type linkOut struct {
	store.Link
	Kind string `json:"kind"`
	// Exists is set for a local link only.
	Exists *bool `json:"exists,omitempty"`
}

// plotOut is the plot object that show, new, set, edit, and export print. It
// is a plot whose links have a kind.
type plotOut struct {
	store.Plot
	Links []linkOut `json:"links"`
}

func newPlotOut(p store.Plot, vaults []string) plotOut {
	out := plotOut{Plot: p, Links: make([]linkOut, len(p.Links))}
	for i, l := range p.Links {
		info := linkkind.Classify(l.Target, vaults)
		out.Links[i] = linkOut{Link: l, Kind: info.Kind}
		if info.Local {
			exists := info.Exists
			out.Links[i].Exists = &exists
		}
	}
	return out
}

// linkPathMissingError is the error of a link whose local path does not exist.
type linkPathMissingError struct {
	plotID, linkID, path string
}

func (e linkPathMissingError) Error() string {
	return fmt.Sprintf("the path does not exist: %s", e.path)
}
func (e linkPathMissingError) Is(target error) bool { return target == ErrLinkPathMissing }
func (e linkPathMissingError) ErrorDetails() any {
	return struct {
		PlotID string `json:"plot_id"`
		LinkID string `json:"link_id"`
		Path   string `json:"path"`
	}{e.plotID, e.linkID, e.path}
}

func newOpenCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "open <plot> <link>",
		Short: "Open a link of a plot",
		Long: "Open a link. <link> is a link ID or an exact label.\n" +
			"A URL opens in the default browser. A file in an Obsidian vault opens in Obsidian, or in its default app when Obsidian is not installed. A folder opens in Finder. Any other file opens in its default app.\n" +
			"A file or a bundle that open would run, such as an executable or an .app, is revealed in Finder instead. A URL with a scheme other than http, https, mailto, obsidian, notion, linear, or slack exits with code 2.\n" +
			"A local path that does not exist exits with code 12.",
		Args: cobra.ExactArgs(2),
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
			l, err := findLink(&p, args[1])
			if err != nil {
				return err
			}
			info := linkkind.Classify(l.Target, linkkind.Vaults())
			via, err := linkkind.Open(info)
			switch {
			case errors.Is(err, linkkind.ErrMissing):
				return linkPathMissingError{p.ID, l.ID, info.Path}
			case errors.Is(err, linkkind.ErrNotURL), errors.Is(err, linkkind.ErrScheme):
				return fmt.Errorf("%v: %w", err, store.ErrInvalid)
			case err != nil:
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Plot       string `json:"plot"`
					LinkID     string `json:"link_id"`
					Kind       string `json:"kind"`
					OpenedWith string `json:"opened_with"`
				}{p.ID, l.ID, info.Kind, via})
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Opened %s.\n", l.Label)
			return nil
		},
	}
}
