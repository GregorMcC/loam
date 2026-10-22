package github

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

// MergeMethod is how GitHub merges a PR into its base branch.
type MergeMethod string

// The merge methods. [MergeMethods] lists them.
const (
	MethodMerge  MergeMethod = "merge"
	MethodSquash MergeMethod = "squash"
	MethodRebase MergeMethod = "rebase"
)

// MergeMethods lists every merge method, in the order of GitHub.
var MergeMethods = []MergeMethod{MethodMerge, MethodSquash, MethodRebase}

// ErrBranchMoved means that the branch on GitHub has commits after the head
// of the PR. Loam keeps such a branch: those commits are not in the PR.
var ErrBranchMoved = errors.New("the branch on GitHub has commits that are not in the PR")

// MergeSettings say how a PR can merge.
type MergeSettings struct {
	// Methods are the merge methods that the repo allows, in the order of
	// [MergeMethods]. It is never empty.
	Methods []MergeMethod
	// Default is the method that GitHub offers first: the method that you
	// last used in the repo, else the default of the repo. It is one of Methods.
	Default MergeMethod
	// Queue is true when the base branch of the PR has a merge queue.
	Queue bool
}

const settingsQuery = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerDefaultMergeMethod
    pullRequest(number: $number) { isMergeQueueEnabled }
  }
}`

// MergeSettings asks GitHub how the PR with the number can merge: the
// methods that the repo allows, the default method, and the merge queue.
func (c *Client) MergeSettings(ctx context.Context, repo Repo, number int) (MergeSettings, error) {
	var data struct {
		Repository struct {
			MergeCommitAllowed       bool   `json:"mergeCommitAllowed"`
			SquashMergeAllowed       bool   `json:"squashMergeAllowed"`
			RebaseMergeAllowed       bool   `json:"rebaseMergeAllowed"`
			ViewerDefaultMergeMethod string `json:"viewerDefaultMergeMethod"`
			PullRequest              *struct {
				IsMergeQueueEnabled bool `json:"isMergeQueueEnabled"`
			} `json:"pullRequest"`
		} `json:"repository"`
	}
	vars := map[string]any{"owner": repo.Owner, "name": repo.Name, "number": number}
	if err := c.query(ctx, settingsQuery, vars, &data); err != nil {
		return MergeSettings{}, err
	}
	r := data.Repository
	allowed := map[MergeMethod]bool{MethodMerge: r.MergeCommitAllowed, MethodSquash: r.SquashMergeAllowed, MethodRebase: r.RebaseMergeAllowed}
	var s MergeSettings
	for _, m := range MergeMethods {
		if allowed[m] {
			s.Methods = append(s.Methods, m)
		}
	}
	if len(s.Methods) == 0 {
		return MergeSettings{}, fmt.Errorf("%w: the answer of GitHub allows no merge method", ErrOffline)
	}
	s.Default = MergeMethod(strings.ToLower(r.ViewerDefaultMergeMethod))
	if !slices.Contains(s.Methods, s.Default) {
		s.Default = s.Methods[0]
	}
	s.Queue = r.PullRequest != nil && r.PullRequest.IsMergeQueueEnabled
	return s, nil
}

// MergeOptions say how to merge a PR.
type MergeOptions struct {
	// Method is empty for a merge queue, which merges with its own method.
	Method MergeMethod
	// Auto turns on auto merge: GitHub merges the PR when its checks pass.
	Auto bool
	// HeadOID is the commit that Loam checked. GitHub refuses the merge when
	// the PR head is another commit.
	HeadOID string
}

// Merge runs gh pr merge. It merges the PR, adds it to the merge queue of its
// base branch, or turns on auto merge. gh decides which from the PR and the
// options, as its help says.
func (c *Client) Merge(ctx context.Context, repo Repo, number int, o MergeOptions) error {
	args := []string{"pr", "merge", strconv.Itoa(number), "--repo", repo.flag()}
	if o.Method != "" {
		args = append(args, "--"+string(o.Method))
	}
	if o.Auto {
		args = append(args, "--auto")
	}
	args = append(args, "--match-head-commit", o.HeadOID)
	return c.act(ctx, fmt.Sprintf("merge PR #%d", number), args...)
}

// RerunFailed runs the failed jobs of a GitHub Actions run again (gh run
// rerun --failed).
func (c *Client) RerunFailed(ctx context.Context, repo Repo, runID int64) error {
	id := strconv.FormatInt(runID, 10)
	return c.act(ctx, "re-run the run "+id, "run", "rerun", id, "--failed", "--repo", repo.flag())
}

// UpdateBranch brings the PR up to date with its base branch on GitHub, with
// a merge commit (gh pr update-branch).
func (c *Client) UpdateBranch(ctx context.Context, repo Repo, number int) error {
	n := strconv.Itoa(number)
	return c.act(ctx, "update PR #"+n, "pr", "update-branch", n, "--repo", repo.flag())
}

// refMissingText is the message of GitHub for a delete of a branch that is
// not there. GitHub gives it with HTTP 422.
const refMissingText = "Reference does not exist"

// DeleteBranch deletes a branch on GitHub when its head is headOID, the head
// of a merged PR. It reads the head first, then deletes the branch. It fails
// with [ErrBranchMoved] when the head is another commit. A branch that is not
// on GitHub, or that GitHub deletes between the read and the delete, is no
// error: GitHub can delete the branch of a merged PR first.
//
// GitHub also gives HTTP 422 when it refuses the delete, such as for a
// protected branch or a ruleset. A 422 means that the branch is gone only
// when GitHub says that the reference does not exist, or a read after it
// gives 404. Else the error has the message of GitHub.
func (c *Client) DeleteBranch(ctx context.Context, repo Repo, branch, headOID string) error {
	out, err := c.run(ctx, ghTimeout, nil, "api", "--hostname", host, repo.refPath("ref", branch))
	if gone(err, "HTTP 404") {
		return nil
	}
	if err != nil {
		return readError(err)
	}
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	if err := json.Unmarshal(out, &ref); err != nil {
		return fmt.Errorf("%w: gh gave an answer that Loam cannot read: %v", ErrOffline, err)
	}
	if ref.Object.SHA != headOID {
		return fmt.Errorf("%w: %s is at %s, and the PR head is %s", ErrBranchMoved, branch, ref.Object.SHA, headOID)
	}
	_, err = c.run(ctx, ghActionTimeout, nil, "api", "--hostname", host, "--method", "DELETE", repo.refPath("refs", branch))
	switch {
	case gone(err, "HTTP 404", refMissingText):
		return nil
	case gone(err, "HTTP 422"):
		if _, readErr := c.run(ctx, ghTimeout, nil, "api", "--hostname", host, repo.refPath("ref", branch)); gone(readErr, "HTTP 404") {
			return nil
		}
	}
	return actionError(err, "delete the branch")
}

// gone reports whether a gh api call failed with one of the texts that GitHub
// gives for a branch that is not there: an HTTP status, or a message.
func gone(err error, statuses ...string) bool {
	var f *ghFailure
	return errors.As(err, &f) && f.says(statuses...)
}

// act runs a gh command that acts on GitHub. what says what the command does,
// for the error.
func (c *Client) act(ctx context.Context, what string, args ...string) error {
	_, err := c.run(ctx, ghActionTimeout, nil, args...)
	return actionError(err, what)
}

// actionError turns a failed gh command that acts on GitHub into an error.
// A refusal keeps the message of GitHub, such as why a PR cannot merge: it
// is not a failure to reach GitHub. A rate limit is [ErrRateLimited].
func actionError(err error, what string) error {
	var f *ghFailure
	switch {
	case !errors.As(err, &f):
		return err
	case f.rateLimited():
		return fmt.Errorf("%w: %s", ErrRateLimited, f.message())
	}
	return fmt.Errorf("could not %s: %s", what, f.message())
}

// flag is the repo for the --repo flag of gh, with the host, so gh never
// picks another host.
func (r Repo) flag() string { return host + "/" + r.Owner + "/" + r.Name }

// refPath is the REST path of a branch: kind is "ref" to read one ref, and
// "refs" to delete it.
func (r Repo) refPath(kind, branch string) string {
	return "repos/" + url.PathEscape(r.Owner) + "/" + url.PathEscape(r.Name) + "/git/" + kind + "/heads/" + escapeBranch(branch)
}
