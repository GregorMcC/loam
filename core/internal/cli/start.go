package cli

import (
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command {
		var repo, sessionID, worktreeName string
		var plotFolder bool
		c := &cobra.Command{
			Use:   "start <plot>",
			Short: "Start a Claude Code session that is seeded with a plot",
			Long: "Write the seed of the plot, record the session, and run claude in this terminal.\n" +
				"The session starts in the main repo of the plot, or in the plot folder if the plot has no repos.\n" +
				"With --plot-folder, it starts in the plot folder, and every repo is an added folder.\n" +
				"With --worktree, it starts in that worktree of the plot. It runs the setup command of the repo first if setup has not succeeded.",
			Args: cobra.ExactArgs(1),
			RunE: func(cmd *cobra.Command, args []string) error {
				s, err := openStore()
				if err != nil {
					return err
				}
				p, err := resolvePlot(s, args[0])
				if err != nil {
					s.Close()
					return err
				}
				exe, err := loamBinary()
				if err != nil {
					s.Close()
					return err
				}
				plan, err := session.Prepare(s, session.StartOptions{PlotID: p.ID, Repo: repo, SessionID: sessionID, Loam: exe, Worktree: worktreeName, PlotFolder: plotFolder})
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
		c.Flags().StringVar(&repo, "repo", "", "start in this repo (ID or path) of the plot, not the main repo. With --worktree: the repo of the worktree")
		c.Flags().StringVar(&worktreeName, "worktree", "", "start in this worktree of the plot (an ID, a folder name, or a name)")
		c.Flags().StringVar(&sessionID, "session-id", "", "use this session UUID")
		c.Flags().BoolVar(&plotFolder, "plot-folder", false, "start in the plot folder, not in a repo. Every repo is an added folder")
		return c
	})
}
