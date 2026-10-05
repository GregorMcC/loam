package cli

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command { return newArchiveCmd(true) })
	Register(func() *cobra.Command { return newArchiveCmd(false) })
	Register(newDeleteCmd)
}

// newArchiveCmd makes loam archive (archive true) or loam unarchive. The flag
// is not a change: it has no change log entry and no undo.
func newArchiveCmd(archive bool) *cobra.Command {
	use, short, long, done := "archive <plot>", "Archive a plot", "", "Archived"
	if archive {
		long = "Archive a plot. It leaves loam list and the MCP list_plots tool. loam start and loam resume refuse it. You can still read and edit it. The archive is not a change: it has no undo."
	} else {
		use, short, done = "unarchive <plot>", "Bring an archived plot back", "Unarchived"
		long = "Bring an archived plot back. It returns to its old place in the plot order."
	}
	return &cobra.Command{
		Use:   use,
		Short: short,
		Long:  long + " <plot> is an ID, a name, or a unique prefix of a name.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			ps, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			if err := s.SetArchived(ps.ID, archive); err != nil {
				return err
			}
			p, err := s.GetPlot(ps.ID)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, newPlotOut(p, linkkind.Vaults()))
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s %s (%s)\n", done, p.Name, p.ID)
			return nil
		},
	}
}

// deleteOut is the --json output of loam delete.
type deleteOut struct {
	Plot string `json:"plot"`
	Name string `json:"name"`
	// Trash is the new path of the plot folder. It is empty when the plot had no folder.
	Trash string `json:"trash"`
	// ClaudeFiles are the folders of Claude Code's own session files for this
	// plot. Loam does not remove them.
	ClaudeFiles []string `json:"claude_files"`
}

func newDeleteCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "delete <plot>",
		Short: "Delete an archived plot that has no worktrees",
		Long: "Delete an archived plot. The plot must have no worktrees.\n" +
			"The command removes the plot, its change log, its session records, its worktree records, and the repo settings that no other plot uses.\n" +
			"It moves the plot folder to the Trash (~/.Trash).\n" +
			"It does not remove the files of Claude Code. It prints their paths, one folder for each start folder of the plot's sessions, so you can remove them.\n" +
			"There is no undo.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			ps, err := resolvePlot(s, args[0])
			if err != nil {
				return err
			}
			recs, err := s.DeletePlot(ps.ID)
			if err != nil {
				return deleteRefusal(ps, err)
			}
			out := deleteOut{Plot: ps.ID, Name: ps.Name, ClaudeFiles: []string{}}
			// Loam's own files for the plot. A failure here leaves a stray file only.
			for _, r := range recs {
				_ = os.Remove(filepath.Join(s.Home(), "sessions", r.SessionID+".json"))
			}
			_ = os.Remove(filepath.Join(s.Home(), "worktrees", ps.ID)) // only when empty
			if _, err := os.Stat(s.PlotDir(ps.ID)); err == nil {
				if out.Trash, err = moveToTrash(s.PlotDir(ps.ID)); err != nil {
					return fmt.Errorf("deleted %s (%s), but the plot folder is still at %s: %w", ps.Name, ps.ID, s.PlotDir(ps.ID), err)
				}
			}
			starts := make([]string, len(recs))
			for i, r := range recs {
				starts[i] = r.StartFolder
			}
			out.ClaudeFiles = claudeProjectFolders(starts)
			if JSON(cmd) {
				return printJSON(cmd, out)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "Deleted %s (%s)\n", ps.Name, ps.ID)
			if out.Trash != "" {
				fmt.Fprintf(w, "The plot folder is now in the Trash: %s\n", out.Trash)
			}
			if len(out.ClaudeFiles) > 0 {
				fmt.Fprintln(w, "Loam did not remove the files of Claude Code for this plot. Remove them yourself if you want to:")
				for _, f := range out.ClaudeFiles {
					fmt.Fprintf(w, "  %s\n", f)
				}
			}
			return nil
		},
	}
}

// deleteRefusal gives a refusal of loam delete a message that says what to do.
func deleteRefusal(ps store.PlotSummary, err error) error {
	switch {
	case errors.Is(err, store.ErrNotArchived):
		return refusal{fmt.Sprintf("%s is not archived. Archive it first with \"loam archive %s\".", ps.Name, ps.ID), store.ErrNotArchived}
	case errors.Is(err, store.ErrHasWorktrees):
		return refusal{fmt.Sprintf("%s has worktrees. Remove them first with \"loam worktree rm\".", ps.Name), store.ErrHasWorktrees}
	}
	return err
}

// refusal is an error with its own text for a person. It wraps a sentinel
// error, so errors.Is still works.
type refusal struct {
	msg string
	err error
}

func (r refusal) Error() string { return r.msg }
func (r refusal) Unwrap() error { return r.err }

// moveToTrash moves a folder into ~/.Trash and returns the new path. A name
// that is taken gets a number: "name 2", "name 3".
func moveToTrash(src string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	trash := filepath.Join(home, ".Trash")
	if err := os.MkdirAll(trash, 0o700); err != nil {
		return "", err
	}
	base := filepath.Base(src)
	dst := filepath.Join(trash, base)
	for n := 2; ; n++ {
		_, err := os.Lstat(dst)
		if errors.Is(err, fs.ErrNotExist) {
			break
		}
		if err != nil {
			return "", err
		}
		dst = filepath.Join(trash, fmt.Sprintf("%s %d", base, n))
	}
	if err := os.Rename(src, dst); err != nil {
		return "", err
	}
	return dst, nil
}

// claudeProjectFolders returns the folders under Claude Code's projects folder
// that belong to the start folders. Claude Code names each one after the start
// folder, with every character that is not an ASCII letter or digit replaced
// by "-". Only folders that exist are returned, once each, in the order of
// the start folders.
func claudeProjectFolders(starts []string) []string {
	root := os.Getenv("CLAUDE_CONFIG_DIR")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return []string{}
		}
		root = filepath.Join(home, ".claude")
	}
	out := []string{}
	seen := map[string]bool{}
	for _, start := range starts {
		dir := filepath.Join(root, "projects", claudeProjectName(start))
		if seen[dir] {
			continue
		}
		seen[dir] = true
		if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
			out = append(out, dir)
		}
	}
	return out
}

// claudeProjectName returns the name that Claude Code gives the projects
// folder of a start folder.
func claudeProjectName(start string) string {
	var b strings.Builder
	for _, c := range start {
		if 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' {
			b.WriteRune(c)
		} else {
			b.WriteByte('-')
		}
	}
	return b.String()
}
