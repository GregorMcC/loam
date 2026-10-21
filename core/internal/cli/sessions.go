package cli

import (
	"fmt"
	"os"
	"slices"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newSessionsCmd)
	Register(newResumeCmd)
}

func newSessionsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "sessions [<plot>]",
		Short: "List session records, newest first",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			plotID := ""
			if len(args) == 1 {
				p, err := resolvePlot(s, args[0])
				if err != nil {
					return err
				}
				plotID = p.ID
			}
			recs, err := s.ListSessions(plotID)
			if err != nil {
				return err
			}
			slices.Reverse(recs)
			if JSON(cmd) {
				return printJSON(cmd, recs)
			}
			names := map[string]string{}
			if plots, err := s.ListPlots(); err == nil {
				for _, p := range plots {
					names[p.ID] = p.Name
				}
			}
			for _, r := range recs {
				fmt.Fprintf(cmd.OutOrStdout(), "%s  %s  %s  %s\n", r.SessionID, r.CreatedAt.Local().Format("2006-01-02 15:04"), names[r.PlotID], r.StartFolder)
			}
			return nil
		},
	}
}

func newResumeCmd() *cobra.Command {
	var plotArg string
	c := &cobra.Command{
		Use:   "resume <session-id>",
		Short: "Resume a seeded Claude Code session",
		Long: "Read the session record, change to its start folder, write the seed again, and run claude --resume.\n" +
			"In a worktree, it runs the setup command first if setup has not succeeded.\n" +
			"The command fails if the start folder is gone.\n" +
			"With --plot, a Home session, which has no record, gets a record in that plot first, with the\n" +
			"home folder as its start folder. The app uses it to move a Home tab to a plot.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			exe, err := loamBinary()
			if err != nil {
				s.Close()
				return err
			}
			var plan *session.Plan
			if plotArg != "" {
				plan, err = resumeInPlot(s, args[0], plotArg, exe)
			} else {
				plan, err = session.PrepareResume(s, args[0], exe)
			}
			s.Close()
			if err != nil {
				return err
			}
			if err := session.BeforeExec(plan, cmd.InOrStdin(), stdinIsTerminal(cmd.InOrStdin()), cmd.OutOrStdout(), cmd.ErrOrStderr()); err != nil {
				return err
			}
			return session.Exec(plan)
		},
	}
	c.Flags().StringVar(&plotArg, "plot", "", "record a Home session in this plot, then resume it")
	return c
}

// resumeInPlot records the Home session in the plot that plotArg names and
// prepares its resume. A Home session always runs in the home folder
// (PrepareHome), so that is its start folder, whatever the current folder.
func resumeInPlot(s *store.Store, sessionID, plotArg, loam string) (*session.Plan, error) {
	p, err := resolvePlot(s, plotArg)
	if err != nil {
		return nil, err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return session.PrepareResumeInPlot(s, sessionID, p.ID, home, loam)
}
