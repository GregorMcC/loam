package session

import (
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/GregorMcC/loam/core/internal/store"
)

// TrustNote is what `loam start` prints before the first session in a new
// worktree. Claude Code asks about each new folder.
const TrustNote = "Claude will ask to trust this folder, choose Yes."

// prepareWorktree adds the worktree to the plan: the note for the first
// session, and the setup command while setup has not succeeded.
func prepareWorktree(s *store.Store, plan *Plan, w store.Worktree, first bool) error {
	plan.Worktree = &w
	plan.TrustNote = first
	if w.SetupDone {
		return nil
	}
	set, err := s.RepoSettings(w.Repo)
	if err != nil {
		return err
	}
	plan.Setup = set.Setup
	plan.SetupApproved = set.Setup == set.SetupApproved
	return nil
}

// firstSessionIn reports whether the plot has no session record that started in dir.
func firstSessionIn(s *store.Store, plotID, dir string) (bool, error) {
	recs, err := s.ListSessions(plotID)
	if err != nil {
		return false, err
	}
	for _, r := range recs {
		if filepath.Clean(r.StartFolder) == filepath.Clean(dir) {
			return false, nil
		}
	}
	return true, nil
}

// worktreeGone is the error for a worktree folder that does not exist.
func worktreeGone(dir string) error {
	return fmt.Errorf("the worktree folder %s is gone. A session cannot start there. Make the worktree again with loam worktree new", dir)
}

// isWorktreeFolder reports whether dir is a folder under the worktrees
// folder of the Loam home.
func isWorktreeFolder(s *store.Store, dir string) bool {
	return strings.HasPrefix(filepath.Clean(dir), filepath.Join(s.Home(), "worktrees")+string(filepath.Separator))
}

// BeforeExec does what a worktree needs before claude starts. It prints the
// trust note for the first session. Then, if setup has not succeeded, it runs
// the setup command in the worktree and records the success. A failed setup
// is a warning on errOut: claude starts anyway, and the next pane runs setup
// again. It does nothing for a plan with no worktree.
//
// A setup command that is new or changed since you last approved it runs
// only after you say yes on in. When in is not a terminal (interactive is
// false), Loam cannot ask, so it skips the command with a warning.
func BeforeExec(p *Plan, in io.Reader, interactive bool, out, errOut io.Writer) error {
	if p.Worktree == nil {
		return nil
	}
	if p.TrustNote {
		fmt.Fprintln(out, TrustNote)
	}
	if p.Setup == "" {
		return nil
	}
	s, err := store.OpenHome()
	if err != nil {
		return err
	}
	defer s.Close()
	if !p.SetupApproved {
		if !interactive {
			fmt.Fprintf(errOut, "Skipped the setup command because it is new or changed: %s\nRun loam start in a terminal to approve it.\n", p.Setup)
			return nil
		}
		fmt.Fprintf(out, "The setup command of %s is new or changed:\n  %s\nRun it? [y/N] ", filepath.Base(p.Worktree.Repo), p.Setup)
		if !readYes(in) {
			fmt.Fprintln(out, "Skipped the setup command. Claude starts anyway. The next pane asks again.")
			return nil
		}
		if err := s.ApproveSetup(p.Worktree.Repo, p.Setup); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "Running the setup command: %s\n", p.Setup)
	cmd := exec.Command("sh", "-c", p.Setup)
	cmd.Dir = p.Worktree.Path
	cmd.Stdin, cmd.Stdout, cmd.Stderr = in, out, errOut
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(errOut, "The setup command failed (%v). Claude starts anyway. The next pane runs setup again.\n", err)
		return nil
	}
	return s.MarkWorktreeSetup(p.Worktree.ID)
}

// readYes reads one line from in, one byte at a time so that nothing after
// the line is consumed, and reports whether it is "y" or "yes".
func readYes(in io.Reader) bool {
	var line []byte
	b := make([]byte, 1)
	for {
		n, err := in.Read(b)
		if n == 1 {
			if b[0] == '\n' {
				break
			}
			line = append(line, b[0])
		}
		if err != nil {
			break
		}
	}
	a := strings.ToLower(strings.TrimSpace(string(line)))
	return a == "y" || a == "yes"
}
