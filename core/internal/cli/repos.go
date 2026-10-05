package cli

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	Register(newRepoCmd)
}

// stdinIsTerminal reports whether the command input is a terminal. A test
// replaces it.
var stdinIsTerminal = func(in any) bool {
	f, ok := in.(*os.File)
	return ok && term.IsTerminal(int(f.Fd()))
}

func newRepoCmd() *cobra.Command {
	c := &cobra.Command{
		Use:   "repo",
		Short: "Add, edit, or remove a repo of a plot, or set the main repo",
		Args:  cobra.NoArgs,
		RunE:  func(cmd *cobra.Command, _ []string) error { return cmd.Help() },
	}
	c.AddCommand(newRepoAddCmd(), newRepoEditCmd(), newRepoRmCmd(), newRepoMainCmd())
	return c
}

// settingsFlags are the worktree settings of a repo. A nil field means that
// the person did not give the flag.
type settingsFlags struct {
	setup *string
	copy  *[]string
}

// addSettingsFlags adds --setup and --copy, and returns a function that reads them.
func addSettingsFlags(c *cobra.Command) func() settingsFlags {
	var setup string
	var files []string
	c.Flags().StringVar(&setup, "setup", "", "the setup command that runs in each new worktree of the repo. An empty value clears it.")
	c.Flags().StringArrayVar(&files, "copy", nil, "a file or glob, relative to the repo, to copy into each new worktree (repeatable). --copy \"\" clears the list.")
	return func() settingsFlags {
		var f settingsFlags
		if c.Flags().Changed("setup") {
			f.setup = &setup
		}
		if c.Flags().Changed("copy") {
			kept := []string{}
			for _, p := range files {
				if p != "" {
					kept = append(kept, p)
				}
			}
			f.copy = &kept
		}
		return f
	}
}

func (f settingsFlags) any() bool { return f.setup != nil || f.copy != nil }

func newRepoAddCmd() *cobra.Command {
	var note string
	var expect []string
	var settings func() settingsFlags
	c := &cobra.Command{
		Use:   "add <plot> <path>",
		Short: "Add a repo to a plot",
		Long: "Add a local git checkout to a plot. The first repo is the main repo.\n" +
			"The repo's remote (origin, else the first remote) is added as a link, unless the plot has it.\n" +
			"Loam then fetches origin and switches the checkout to the default branch of origin, at its latest commit.\n" +
			"A checkout with uncommitted changes keeps its branch, with a warning.\n" +
			"--setup and --copy set the worktree settings of the repo path. Every plot that holds the path shares them.",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			// A leading ~ is your home folder. The app runs loam in /, so Abs alone would give "/~/...".
			abs, err := filepath.Abs(linkkind.Expand(args[1]))
			if err != nil {
				return err
			}
			if err := store.CheckRepoFolder(abs); err != nil {
				return err
			}
			return writeRepo(cmd, args[0], expect, settings(), worktree.SwitchToDefault, func(p *store.Plot) ([]store.Edit, error) {
				edits := []store.Edit{{Op: store.OpAddRepo, Path: store.S(abs), Note: store.S(note)}}
				// The repo's remote comes as a link in the same change, so one undo removes both.
				if link, ok := gitremote.LinkEdit(*p, abs); ok {
					edits = append(edits, link)
				}
				return edits, nil
			})
		},
	}
	c.Flags().StringVar(&note, "note", "", "a note for the repo")
	settings = addSettingsFlags(c)
	addExpectFlag(c, &expect)
	return c
}

func newRepoEditCmd() *cobra.Command {
	var note string
	var expect []string
	var settings func() settingsFlags
	c := &cobra.Command{
		Use:   "edit <plot> <repo>",
		Short: "Change the note or the worktree settings of a repo",
		Long: "Change a repo. <repo> is a repo ID or a path.\n" +
			"--setup and --copy set the worktree settings of the repo path. Every plot that holds the path shares them.",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !cmd.Flags().Changed("note") && !settings().any() {
				return fmt.Errorf("give --note, --setup, or --copy: %w", store.ErrInvalid)
			}
			return writeRepo(cmd, args[0], expect, settings(), nil, func(p *store.Plot) ([]store.Edit, error) {
				r, err := worktree.FindRepo(*p, args[1])
				if err != nil {
					return nil, err
				}
				e := store.Edit{Op: store.OpUpdateRepo, Item: store.RepoItem(r.ID)}
				if cmd.Flags().Changed("note") {
					e.Note = store.S(note)
				}
				return []store.Edit{e}, nil
			})
		},
	}
	c.Flags().StringVar(&note, "note", "", "the new note")
	settings = addSettingsFlags(c)
	addExpectFlag(c, &expect)
	return c
}

func newRepoMainCmd() *cobra.Command {
	var expect []string
	c := &cobra.Command{
		Use:   "main <plot> <repo>",
		Short: "Make a repo the main repo",
		Long:  "Make a repo the main repo. <repo> is a repo ID or a path.",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return writeRepo(cmd, args[0], expect, settingsFlags{}, nil, func(p *store.Plot) ([]store.Edit, error) {
				r, err := worktree.FindRepo(*p, args[1])
				if err != nil {
					return nil, err
				}
				return []store.Edit{{Op: store.OpSetMainRepo, Item: store.RepoItem(r.ID)}}, nil
			})
		},
	}
	addExpectFlag(c, &expect)
	return c
}

func newRepoRmCmd() *cobra.Command {
	var expect []string
	var newMain string
	c := &cobra.Command{
		Use:   "rm <plot> <repo>",
		Short: "Remove a repo from a plot",
		Long: "Remove a repo. <repo> is a repo ID or a path.\n" +
			"If you remove the main repo and more than one repo remains, pick the new main repo.\n" +
			"The command fails while the plot has worktrees of the repo.\n" +
			"On a terminal, the command asks. Otherwise, or with --json, give --main.",
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return writeRepo(cmd, args[0], expect, settingsFlags{}, nil, func(p *store.Plot) ([]store.Edit, error) {
				r, err := worktree.FindRepo(*p, args[1])
				if err != nil {
					return nil, err
				}
				edits := []store.Edit{{Op: store.OpRemoveRepo, Item: store.RepoItem(r.ID)}}
				var rest []store.Repo
				for _, o := range p.Repos {
					if o.ID != r.ID {
						rest = append(rest, o)
					}
				}
				if newMain != "" {
					m, err := worktree.FindRepo(*p, newMain)
					if err != nil {
						return nil, err
					}
					if m.ID == r.ID {
						return nil, fmt.Errorf("--main names the repo you remove: %w", store.ErrInvalid)
					}
					if r.Main {
						edits = append(edits, store.Edit{Op: store.OpSetMainRepo, Item: store.RepoItem(m.ID)})
					}
					return edits, nil
				}
				if r.Main && len(rest) > 1 {
					m, err := pickMain(cmd, rest)
					if err != nil {
						return nil, err
					}
					edits = append(edits, store.Edit{Op: store.OpSetMainRepo, Item: store.RepoItem(m.ID)})
				}
				return edits, nil
			})
		},
	}
	c.Flags().StringVar(&newMain, "main", "", "the repo (ID or path) that becomes the main repo")
	addExpectFlag(c, &expect)
	return c
}

// pickMain asks the person to choose a new main repo from rest.
func pickMain(cmd *cobra.Command, rest []store.Repo) (store.Repo, error) {
	in := cmd.InOrStdin()
	if JSON(cmd) || !stdinIsTerminal(in) {
		return store.Repo{}, fmt.Errorf("this repo is the main repo and %d others remain: run again with --main <repo> to pick the new main repo: %w", len(rest), store.ErrInvalid)
	}
	out := cmd.OutOrStdout()
	fmt.Fprintln(out, "This repo is the main repo. Pick the new main repo:")
	for i, r := range rest {
		fmt.Fprintf(out, "  %d. %s\n", i+1, r.Path)
	}
	fmt.Fprintf(out, "Number (1 to %d): ", len(rest))
	line, _ := bufio.NewReader(in).ReadString('\n')
	n, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil || n < 1 || n > len(rest) {
		return store.Repo{}, fmt.Errorf("no valid choice, nothing changed: %w", store.ErrInvalid)
	}
	return rest[n-1], nil
}

// writeRepo resolves the plot, builds the edits, commits them, and prints the result.
// With settings, it also saves the worktree settings of the repo path. They
// are not a change, so they do not move the change ID.
// after, when it is not nil, runs on the path of the repo that the write
// added, and returns warnings. A repo add uses it to switch the checkout.
func writeRepo(cmd *cobra.Command, plotArg string, expectVals []string, settings settingsFlags, after func(path string) []string, build func(*store.Plot) ([]store.Edit, error)) error {
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
	saved := false
	if settings.any() {
		path := ""
		for _, r := range res.Plot.Repos {
			if store.RepoItem(r.ID) == item {
				path = r.Path
			}
		}
		if err := s.SetRepoSettings(path, settings.setup, settings.copy); err != nil {
			return err
		}
		// You typed this setup command, so it needs no question before it runs.
		if settings.setup != nil {
			if err := s.ApproveSetup(path, *settings.setup); err != nil {
				return err
			}
		}
		if res.Plot, err = s.GetPlot(res.Plot.ID); err != nil {
			return err
		}
		saved = true
	}
	var repo *store.Repo
	for i := range res.Plot.Repos {
		if store.RepoItem(res.Plot.Repos[i].ID) == item {
			repo = &res.Plot.Repos[i]
		}
	}
	var warnings []string
	if after != nil && repo != nil && res.ChangeID != 0 {
		warnings = after(repo.Path)
		printWarnings(cmd, warnings)
	}
	if JSON(cmd) {
		return printJSON(cmd, struct {
			ChangeID int64       `json:"change_id"`
			Plot     string      `json:"plot"`
			Repo     *store.Repo `json:"repo,omitempty"`
			Warnings []string    `json:"warnings,omitempty"`
		}{res.ChangeID, res.Plot.ID, repo, warnings})
	}
	out := cmd.OutOrStdout()
	switch {
	case res.ChangeID == 0 && saved:
		fmt.Fprintln(out, "Saved the worktree settings.")
	case res.ChangeID == 0:
		fmt.Fprintln(out, "No change.")
	case edits[0].Op == store.OpRemoveRepo:
		fmt.Fprintln(out, "Removed the repo.")
	case repo != nil:
		fmt.Fprintf(out, "Repo %s: %s\n", repo.ID, repo.Path)
	}
	return nil
}
