// Package github reads the pull requests of branches from GitHub, and acts
// on them, through the gh CLI. Loam holds no credentials: gh signs in and
// sends each request.
//
// [Client.Fetch] runs at most two GraphQL queries for one repo: one for the
// pull requests and the branches on GitHub, and one for the checks and
// reviews of the open pull requests. It reads and never writes.
//
// The commands that act on GitHub are [Client.Merge], [Client.RerunFailed],
// [Client.UpdateBranch], and [Client.DeleteBranch]. `loam worktree land`,
// `rerun`, and `update` run them, and only when you ask. [Client.CreatePR]
// opens the PR of a run that passed its gate (`loam run tick`).
package github

import (
	"errors"
	"net/url"
	"strings"
	"time"
)

// host is the one GitHub host that Loam asks.
const host = "github.com"

// The errors of [Client.Fetch] and [NewClient]. An error that is not one of
// the first four, and is not a cancelled context, wraps ErrOffline.
var (
	// ErrGHMissing means gh is not on PATH or in an install folder.
	ErrGHMissing = errors.New("the GitHub CLI (gh) is not installed")
	// ErrSignedOut means gh has no valid sign-in for github.com.
	ErrSignedOut = errors.New("the GitHub CLI (gh) is signed out. Run: gh auth login")
	// ErrNoAccess means gh cannot read the repo: no access, or SSO not authorized.
	ErrNoAccess = errors.New("the GitHub CLI (gh) cannot read the repo. Run: gh auth status")
	// ErrRateLimited means GitHub refused the request for its rate limit.
	ErrRateLimited = errors.New("GitHub refused the request for its rate limit")
	// ErrOffline means gh got no usable answer from GitHub: no network, a
	// timeout, or another failed request.
	ErrOffline = errors.New("could not reach GitHub")
)

// Repo is a repo on github.com.
type Repo struct {
	Owner string
	Name  string
}

// ParseRepo returns the repo of a web URL such as
// https://github.com/owner/name. It returns false for a URL on another host.
func ParseRepo(webURL string) (Repo, bool) {
	u, err := url.Parse(webURL)
	if err != nil || !strings.EqualFold(u.Hostname(), host) {
		return Repo{}, false
	}
	owner, name, ok := strings.Cut(strings.Trim(u.Path, "/"), "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
		return Repo{}, false
	}
	return Repo{Owner: owner, Name: name}, true
}

// CompareURL returns the page that compares the branch head with the branch
// base, where a person can open a pull request. With an empty base, GitHub
// compares head with the default branch of the repo.
func (r Repo) CompareURL(base, head string) string {
	spec := escapeBranch(head)
	if base != "" {
		spec = escapeBranch(base) + "..." + spec
	}
	return "https://" + host + "/" + url.PathEscape(r.Owner) + "/" + url.PathEscape(r.Name) + "/compare/" + spec
}

// escapeBranch escapes a branch name for a URL path. It keeps the slashes,
// so a branch such as feature/search stays readable.
func escapeBranch(name string) string {
	parts := strings.Split(name, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// Branch is what GitHub knows about one branch.
type Branch struct {
	// PR is the pull request that has the branch as its head, or nil. An open
	// PR wins over a merged or closed one. Else the newest PR wins. A PR from
	// a fork does not count.
	PR *PR
	// Pushed is true when the branch is on GitHub.
	Pushed bool
}

// PR is a pull request, with the counts that a status line needs. The
// counts from BehindBase to ReviewThreads are for an open PR only. They are
// zero or empty for a merged or closed PR.
type PR struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	URL    string `json:"url"`
	// State is OPEN, CLOSED, or MERGED.
	State string `json:"state"`
	Draft bool   `json:"draft"`
	// Mergeable is MERGEABLE, CONFLICTING, or UNKNOWN while GitHub checks.
	Mergeable string `json:"mergeable"`
	// MergeState is the mergeStateStatus of GitHub, such as CLEAN, BEHIND,
	// BLOCKED, or DIRTY.
	MergeState string `json:"merge_state"`
	// ReviewDecision is APPROVED, CHANGES_REQUESTED, or REVIEW_REQUIRED. It
	// is empty when the base branch needs no review.
	ReviewDecision string `json:"review_decision"`
	InMergeQueue   bool   `json:"in_merge_queue"`
	// QueuePosition is the place in the merge queue, from 1. It is 0 out of the queue.
	QueuePosition int `json:"queue_position"`
	// Base and Head are branch names.
	Base     string     `json:"base"`
	Head     string     `json:"head"`
	HeadOID  string     `json:"head_oid"`
	MergedAt *time.Time `json:"merged_at,omitempty"`
	ClosedAt *time.Time `json:"closed_at,omitempty"`
	// Commits counts the commits of the PR.
	Commits int `json:"commits"`
	// BehindBase counts the commits of the base branch that the head does not have.
	BehindBase int `json:"behind_base"`
	// Approvals counts the reviewers with write access whose last review approves.
	Approvals int `json:"approvals"`
	// Comments counts the review threads that are not resolved.
	Comments int    `json:"comments"`
	Checks   Checks `json:"checks"`
	// FailedChecks are the checks that failed, in the order of GitHub.
	FailedChecks []Check `json:"failed_checks"`
	// PassedChecks are the checks that passed, in the order of GitHub. A
	// skipped or neutral check passed too, so the list is as long as
	// Checks.Passed. A cache row from before Loam stored the passed checks
	// gives an empty list until the next refresh. Like FailedChecks, it is a
	// list and never null.
	PassedChecks []Check `json:"passed_checks"`
	// ChangeRequests are the reviews that request changes: the last review
	// of each reviewer with write access, when it requests changes. The
	// list is of the first 100 reviewers, and it is never null.
	ChangeRequests []Review `json:"change_requests"`
	// ReviewThreads are the review threads that are not resolved, of the
	// first 100, in the order of GitHub. Comments counts them. The list is
	// never null.
	ReviewThreads []ReviewThread `json:"review_threads"`
}

// Review is one review of a PR.
type Review struct {
	// ID is the node ID of the review on GitHub.
	ID string `json:"id"`
	// Author is the login of the reviewer.
	Author string `json:"author"`
	// Body is the text of the review, in Markdown. It is empty when the
	// review has only comments on lines.
	Body string `json:"body"`
	URL  string `json:"url"`
}

// ReviewThread is one review thread of a PR: comments on a line of a file.
type ReviewThread struct {
	// ID is the node ID of the thread on GitHub, which Loam and a session
	// need to reply on it and to resolve it.
	ID   string `json:"id"`
	Path string `json:"path"`
	// Line is the line in the head of the PR. It is 0 when the head no
	// longer has the line.
	Line int `json:"line"`
	// URL is the page of the first comment.
	URL string `json:"url"`
	// Comments are the first comments of the thread, oldest first, at most
	// [CommentsPerThread].
	Comments []ReviewComment `json:"comments"`
}

// ReviewComment is one comment of a review thread.
type ReviewComment struct {
	// Author is the login of the person or app that wrote the comment.
	Author string `json:"author"`
	// Writer is true when the author can push to the repo. On a public repo,
	// anyone can comment. A comment that has no review uses the association
	// of its author: OWNER, MEMBER, and COLLABORATOR count as writers.
	Writer bool `json:"writer"`
	// Body is the text of the comment, in Markdown.
	Body string `json:"body"`
	URL  string `json:"url"`
}

// Checks counts the checks of the head commit of a PR.
type Checks struct {
	// State is the summary of GitHub: SUCCESS, FAILURE, ERROR, PENDING, or
	// EXPECTED. It is empty when the head commit has no checks.
	State   string `json:"state"`
	Total   int    `json:"total"`
	Passed  int    `json:"passed"`
	Failed  int    `json:"failed"`
	Running int    `json:"running"`
	// Waiting counts the checks that wait for a person, such as a workflow
	// that needs approval.
	Waiting int `json:"waiting"`
	// Required counts the checks that the base branch needs to pass before a
	// merge. RequiredPassed counts those that passed.
	Required       int `json:"required"`
	RequiredPassed int `json:"required_passed"`
}

// Check is one check of the head commit of a PR, a failed one or a passed one.
type Check struct {
	// Name is the check name. A GitHub Actions job has its workflow name
	// first, such as "lint / swiftformat".
	Name string `json:"name"`
	// URL is the page of the check, with its log.
	URL string `json:"url"`
	// Duration is the run time in seconds. It is 0 when GitHub gives no start or end.
	Duration int `json:"duration"`
	// Required is true when the base branch needs the check to pass before a merge.
	Required bool `json:"required"`
	// RunID is the GitHub Actions run of the check, which Loam can run
	// again. It is 0 for a check that is not a job of GitHub Actions.
	RunID int64 `json:"run_id,omitempty"`
}
