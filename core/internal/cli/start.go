package cli

import (
	"errors"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/spf13/cobra"
)

func init() {
	Register(func() *cobra.Command {
		var repo, sessionID, worktreeName, resume string
		var plotFolder, home bool
		c := &cobra.Command{
			Use:   "start (<plot> | --home)",
			Short: "Start a Claude Code session that is seeded with a plot",
			Long: "Write the seed of the plot, record the session, and run claude in this terminal.\n" +
				"The session starts in the main repo of the plot, or in the plot folder if the plot has no repos.\n" +
				"With --plot-folder, it starts in the plot folder, and every repo is an added folder.\n" +
				"With --worktree, it starts in that worktree of the plot. It runs the setup command of the repo first if setup has not succeeded.\n" +
				"With --home, it starts a session that belongs to no plot, in the home folder, with no seed. The app uses it for Home.",
			Args: func(cmd *cobra.Command, args []string) error {
				if !home {
					if resume != "" {
						return errors.New("--resume goes only with --home. To resume a seeded session, run loam resume")
					}
					return cobra.ExactArgs(1)(cmd, args)
				}
				switch {
				case len(args) > 0:
					return errors.New("--home takes no plot")
				case repo != "" || worktreeName != "" || plotFolder:
					return errors.New("--home does not go with --repo, --worktree, or --plot-folder")
				}
				return nil
			},
			RunE: func(cmd *cobra.Command, args []string) error {
				if home {
					return startHome(session.HomeOptions{SessionID: sessionID, Resume: resume})
				}
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
		c.Flags().BoolVar(&home, "home", false, "start a session that belongs to no plot, in the home folder")
		c.Flags().StringVar(&resume, "resume", "", "with --home: resume this Home session")
		return c
	})
}

// startHome runs a Home session in this terminal.
func startHome(o session.HomeOptions) error {
	exe, err := loamBinary()
	if err != nil {
		return err
	}
	o.Loam = exe
	s, err := openStore()
	if err != nil {
		return err
	}
	plan, err := session.PrepareHome(s, o)
	s.Close()
	if err != nil {
		return err
	}
	return session.Exec(plan)
}
