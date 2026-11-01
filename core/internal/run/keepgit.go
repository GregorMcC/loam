package run

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// rebuildWait is how long [keepGit] waits for a rebuild in another Loam
// process, and rebuildPoll is how often it tries the lock.
const (
	rebuildWait = 30 * time.Second
	rebuildPoll = 50 * time.Millisecond
)

// gitEvent is the kind of the event that says that Loam rebuilt the git
// metadata of the worktree of a run.
const gitEvent = "git"

// keepGit runs before Loam runs git in the worktree of the run r: in a tick,
// a land, a resume, and the gate. The session of a run can write the git
// folder of the repo, which holds the metadata of every worktree, and git
// worktree prune there deletes the metadata of each worktree that its
// sandbox does not show. keepGit rebuilds the metadata of the worktree of r
// when it is gone (see [worktree.Rebuild]), and records a "git" event. It
// returns a *[worktree.RebuildError] when Loam does not rebuild it: the
// caller stops the run with the error as its note. A run whose worktree the
// store does not have is as it was.
func keepGit(ctx context.Context, s *store.Store, r store.Run) error {
	if r.WorktreeID == "" {
		return nil
	}
	w, err := s.GetWorktree(r.WorktreeID)
	if errors.Is(err, store.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	rebuilt, err := worktree.Rebuild(ctx, w, func(ctx context.Context) (func(), error) {
		return waitRebuildLock(ctx, s.Home())
	})
	if err != nil || !rebuilt {
		return err
	}
	return s.AddRunEvent(r.ID, gitEvent, fmt.Sprintf(
		"The git metadata of %s was gone. Loam rebuilt it on %s and kept the files", w.Path, w.Branch))
}

// waitRebuildLock takes the lock of a rebuild in home, which no run can
// write, so a session cannot hold the lock. It waits for another Loam
// process that holds it, at most [rebuildWait].
func waitRebuildLock(ctx context.Context, home string) (func(), error) {
	ctx, cancel := context.WithTimeout(ctx, rebuildWait)
	defer cancel()
	for {
		unlock, ok, err := lockFile(filepath.Join(home, "run-git.lock"))
		if err != nil || ok {
			return unlock, err
		}
		select {
		case <-ctx.Done():
			return nil, errors.New("another Loam process rebuilds the git metadata of a worktree, and it did not end in time")
		case <-time.After(rebuildPoll):
		}
	}
}

// gitRefused reports whether err is a *[worktree.RebuildError] from
// [keepGit].
func gitRefused(err error) bool {
	var re *worktree.RebuildError
	return errors.As(err, &re)
}
