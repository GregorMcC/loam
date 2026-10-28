package run

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// A group is the runs that one split shape made for one issue, one in each
// repo that the issue needs changes in. They share the issue: its Linear
// issue moves to Done when the last of them lands.

// groupRuns returns the other runs of the group of r, or none for a run
// alone.
func groupRuns(s *store.Store, r store.Run) ([]store.Run, error) {
	if r.GroupID == "" {
		return nil, nil
	}
	runs, err := s.ListRuns(r.PlotID)
	if err != nil {
		return nil, err
	}
	return slices.DeleteFunc(runs, func(o store.Run) bool { return o.GroupID != r.GroupID || o.ID == r.ID }), nil
}

// groupRepos names the repos of the other runs of the group of r, as a PR
// body names them: owner/name on GitHub, else the folder name. A run that
// you stopped does not count.
func groupRepos(s *store.Store, plot store.Plot, r store.Run) ([]string, error) {
	runs, err := groupRuns(s, r)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, o := range runs {
		if o.State == store.RunCancelled || o.Shape == nil {
			continue
		}
		repo, err := worktree.FindRepo(plot, o.Shape.Repo)
		if err != nil {
			continue // the repo left the plot
		}
		if name := repoName(repo); !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	slices.Sort(names)
	return names, nil
}

// repoName is the GitHub owner/name of the repo, or its folder name. It is
// not a local path, because a PR body can be public.
func repoName(repo store.Repo) string {
	if web, ok := gitremote.Origin(repo.Path); ok {
		if gr, ok := github.ParseRepo(web); ok {
			return gr.Owner + "/" + gr.Name
		}
	}
	return filepath.Base(repo.Path)
}

// joinAnd joins names as "a", "a and b", or "a, b and c".
func joinAnd(names []string) string {
	if len(names) < 2 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

// finishLinearIssue moves the Linear issue of a run that has ended to Done,
// when that update to Linear is on. A run of a group moves it only when
// every other run of the group has ended as Landed or Cancelled, and one run
// of the group landed. While a run of the group has not landed, a run that
// lands records why the issue stays.
func finishLinearIssue(ctx context.Context, s *store.Store, r store.Run) string {
	if r.Source == nil || r.Source.Kind != intake.Linear {
		return ""
	}
	runs, err := groupRuns(s, r)
	if err != nil {
		return err.Error()
	}
	waiting, landed := 0, r.State == store.RunLanded
	for _, o := range runs {
		switch o.State {
		case store.RunLanded:
			landed = true
		case store.RunCancelled:
		default:
			waiting++
		}
	}
	switch {
	case waiting > 0 && r.State == store.RunLanded:
		left := "1 more run of the issue has"
		if waiting > 1 {
			left = fmt.Sprintf("%d more runs of the issue have", waiting)
		}
		if err := s.AddRunEvent(r.ID, "linear", fmt.Sprintf("%s stays In Progress: %s not landed", r.Source.Key, left)); err != nil {
			return err.Error()
		}
		return ""
	case waiting > 0 || !landed:
		return ""
	}
	if off, warning := linearUpdateOff(s, r, "move "+r.Source.Key+" to Done",
		func(u store.LinearUpdates) bool { return u.Done }); off {
		return warning
	}
	return moveLinearIssue(ctx, s, r, "Done", "has ended", (*linear.Client).Finish)
}

// linkRepo returns the repo of the plot that the link is a GitHub issue of.
// The link is a URL, or the ID of a link of the plot.
func linkRepo(plot store.Plot, link string) (store.Repo, bool) {
	target := strings.TrimSpace(link)
	for _, l := range plot.Links {
		if l.ID == target {
			target = l.Target
		}
	}
	if target == "" {
		return store.Repo{}, false
	}
	for _, repo := range plot.Repos {
		// The key of an issue of the repo itself is "#57".
		if web, ok := gitremote.Origin(repo.Path); ok && strings.HasPrefix(linkkind.IssueKey(target, web), "#") {
			return repo, true
		}
	}
	return store.Repo{}, false
}
