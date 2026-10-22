// Package worktree makes, checks, and removes the git worktrees of a plot.
//
// It runs a fixed set of git commands: fetch, worktree add, worktree remove,
// and branch -d. It runs branch -D only for the branch of a merged PR whose
// tip is the PR head or an earlier commit of the PR (see [Remove]). For a
// repo add, it also runs switch and merge --ff-only on the normal checkout
// (see [SwitchToDefault]). It never runs the setup command of a repo. `loam
// start` runs the setup command.
//
// It reads the pull request of each branch from GitHub through gh and keeps
// it in the PR cache (see [RefreshPRs] and [StageOf]). It acts on GitHub only
// in [Land], [Rerun], and [Update]: Land merges a PR and deletes its branch
// on GitHub, Rerun runs failed checks again, and Update brings a PR up to
// date with its base branch.
package worktree

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// gitTimeout stops a git command that waits for the network or for a prompt.
const gitTimeout = 2 * time.Minute

// gitError is a failed git command. Its text is the first line of what git said.
type gitError struct {
	args   []string
	stderr string
	err    error
}

func (e *gitError) Error() string {
	msg := strings.TrimSpace(e.stderr)
	if i := strings.IndexByte(msg, '\n'); i >= 0 && strings.HasPrefix(msg, "error:") {
		msg = msg[:i]
	}
	if msg == "" {
		msg = e.err.Error()
	}
	return fmt.Sprintf("git %s: %s", e.args[0], msg)
}

func (e *gitError) Unwrap() error { return e.err }

// git runs git in dir and returns the trimmed standard output.
func git(dir string, args ...string) (string, error) {
	return gitContext(context.Background(), dir, args...)
}

// gitContext is [git] that also stops when ctx ends.
func gitContext(ctx context.Context, dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		return strings.TrimSpace(out.String()), &gitError{args: args, stderr: errOut.String(), err: err}
	}
	return strings.TrimSpace(out.String()), nil
}

// gitOK runs git and reports whether it exited with 0.
func gitOK(dir string, args ...string) bool {
	_, err := git(dir, args...)
	return err == nil
}

// exitCode returns the exit code of a failed git command, or -1.
func exitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}

// hasRemote reports whether the repo has a remote with this name.
func hasRemote(repo, name string) bool {
	out, err := git(repo, "remote")
	if err != nil {
		return false
	}
	for _, r := range strings.Fields(out) {
		if r == name {
			return true
		}
	}
	return false
}
