package github

import (
	"context"
	"fmt"
	"path"
	"strconv"
	"strings"
)

// NewPR is a pull request for [Client.CreatePR] to open.
type NewPR struct {
	// Head is the branch to merge, and Base the branch to merge into. An
	// empty Base is the default branch of the repo.
	Head, Base string
	Title      string
	Body       string
}

// OpenedPR is a pull request that [Client.CreatePR] opened.
type OpenedPR struct {
	Number int
	URL    string
}

// CreatePR opens a pull request (gh pr create). The head branch must be on
// GitHub.
func (c *Client) CreatePR(ctx context.Context, repo Repo, p NewPR) (OpenedPR, error) {
	args := []string{"pr", "create", "--repo", repo.flag(), "--head", p.Head, "--title", p.Title, "--body-file", "-"}
	if p.Base != "" {
		args = append(args, "--base", p.Base)
	}
	out, err := c.run(ctx, ghActionTimeout, []byte(p.Body), args...)
	if err != nil {
		return OpenedPR{}, actionError(err, "open a PR")
	}
	// gh prints the URL of the PR last.
	words := strings.Fields(string(out))
	if len(words) == 0 {
		return OpenedPR{}, fmt.Errorf("%w: gh opened a PR, but printed no URL", ErrOffline)
	}
	url := words[len(words)-1]
	number, err := strconv.Atoi(path.Base(url))
	if err != nil {
		return OpenedPR{}, fmt.Errorf("%w: gh printed %q, which is not the URL of a PR", ErrOffline, url)
	}
	return OpenedPR{Number: number, URL: url}, nil
}

// FailedLog returns the last lines of the log of the failed jobs of a GitHub
// Actions run (gh run view --log-failed). Each line starts with the job and
// the step.
func (c *Client) FailedLog(ctx context.Context, repo Repo, runID int64, lines int) (string, error) {
	out, err := c.run(ctx, ghTimeout, nil, "run", "view", strconv.FormatInt(runID, 10), "--repo", repo.flag(), "--log-failed")
	if err != nil {
		return "", actionError(err, "read the log of the run "+strconv.FormatInt(runID, 10))
	}
	all := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(all) > lines {
		all = all[len(all)-lines:]
	}
	return strings.Join(all, "\n") + "\n", nil
}
