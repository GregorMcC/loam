package github

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// prsPerHead is how many PRs the first query reads for each branch, newest
// first. GitHub matches the head name in forks too, and [pick] skips those
// PRs. On a large public repo, many forks can use a common name such as
// patch-1, so Loam reads a full page to find the PR of the repo itself.
const prsPerHead = maxNodes

// maxNodes is the largest page that GitHub gives. Loam reads one page, to
// keep to two queries for each repo. For a PR with more checks, reviews, or
// review threads than this, only the total of the checks counts them all.
// The other counts and the lists of checks are of the first page.
const maxNodes = 100

// CommentsPerThread is how many comments Loam reads of each review thread,
// oldest first. A thread with this many comments can have more. It keeps
// the second query small: a PR can have 100 threads.
const CommentsPerThread = 10

// The first query reads the PRs and the ref of each branch. A branch has the
// aliases pr<i> and ref<i>, and the variables h<i> (the branch) and q<i>
// (its full ref name). It asks for the PRs by head name, not through the
// ref, so a PR still shows after GitHub deletes its branch.
const prQuery = `query($owner: String!, $name: String!%s) {
  repository(owner: $owner, name: $name) {
%s  }
}
fragment pr on PullRequest {
  number title url state isDraft isCrossRepository mergeable mergeStateStatus reviewDecision
  isInMergeQueue mergeQueueEntry { position }
  baseRefName headRefName headRefOid mergedAt closedAt
  commits { totalCount }
}`

const prFields = `    pr%[1]d: pullRequests(headRefName: $h%[1]d, first: %[2]d, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } }
    ref%[1]d: ref(qualifiedName: $q%[1]d) { name }
`

// The second query reads the checks and reviews of each open PR. A PR has
// the alias p<i>, and the variables n<i> (its number) and h<i> (its head).
// isRequired needs the PR number, so the first query cannot ask for it. The
// compare part is only for a head that is on GitHub: GitHub fails the whole
// query when the head is gone.
const detailQuery = `query($owner: String!, $name: String!%s) {
  repository(owner: $owner, name: $name) {
%s  }
}`

const detailFields = `    p%[1]d: pullRequest(number: $n%[1]d) {
      %[3]s
      latestOpinionatedReviews(first: %[2]d, writersOnly: true) { nodes { id state body url author { login } } }
      reviewThreads(first: %[2]d) { nodes { id isResolved path line
        comments(first: %[4]d) { nodes { body url authorAssociation author { login } pullRequestReview { authorCanPushToRepository } } } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: %[2]d) { totalCount nodes {
        __typename
        ... on CheckRun { name status conclusion detailsUrl startedAt completedAt isRequired(pullRequestNumber: $n%[1]d)
          checkSuite { workflowRun { databaseId workflow { name } } } }
        ... on StatusContext { context state targetUrl isRequired(pullRequestNumber: $n%[1]d) }
      } } } } } }
    }
`

const compareField = `baseRef { compare(headRef: $h%d) { behindBy } }`

type prNode struct {
	Number            int    `json:"number"`
	Title             string `json:"title"`
	URL               string `json:"url"`
	State             string `json:"state"`
	IsDraft           bool   `json:"isDraft"`
	IsCrossRepository bool   `json:"isCrossRepository"`
	Mergeable         string `json:"mergeable"`
	MergeStateStatus  string `json:"mergeStateStatus"`
	ReviewDecision    string `json:"reviewDecision"`
	IsInMergeQueue    bool   `json:"isInMergeQueue"`
	MergeQueueEntry   *struct {
		Position int `json:"position"`
	} `json:"mergeQueueEntry"`
	BaseRefName string     `json:"baseRefName"`
	HeadRefName string     `json:"headRefName"`
	HeadRefOid  string     `json:"headRefOid"`
	MergedAt    *time.Time `json:"mergedAt"`
	ClosedAt    *time.Time `json:"closedAt"`
	Commits     struct {
		TotalCount int `json:"totalCount"`
	} `json:"commits"`
}

type detailNode struct {
	BaseRef *struct {
		Compare *struct {
			BehindBy int `json:"behindBy"`
		} `json:"compare"`
	} `json:"baseRef"`
	LatestOpinionatedReviews struct {
		Nodes []struct {
			ID     string  `json:"id"`
			State  string  `json:"state"`
			Body   string  `json:"body"`
			URL    string  `json:"url"`
			Author *author `json:"author"`
		} `json:"nodes"`
	} `json:"latestOpinionatedReviews"`
	ReviewThreads struct {
		Nodes []struct {
			ID         string `json:"id"`
			IsResolved bool   `json:"isResolved"`
			Path       string `json:"path"`
			// Line is null for a thread on a line that the head no longer has.
			Line     *int `json:"line"`
			Comments struct {
				Nodes []struct {
					Body   string  `json:"body"`
					URL    string  `json:"url"`
					Author *author `json:"author"`
					// AuthorAssociation is how the author is part of the repo,
					// such as OWNER or NONE.
					AuthorAssociation string `json:"authorAssociation"`
					// PullRequestReview is the review that the comment is part
					// of. It can be null, so [isWriter] then uses
					// AuthorAssociation.
					PullRequestReview *commentReview `json:"pullRequestReview"`
				} `json:"nodes"`
			} `json:"comments"`
		} `json:"nodes"`
	} `json:"reviewThreads"`
	Commits struct {
		Nodes []struct {
			Commit struct {
				StatusCheckRollup *struct {
					State    string `json:"state"`
					Contexts struct {
						TotalCount int         `json:"totalCount"`
						Nodes      []checkNode `json:"nodes"`
					} `json:"contexts"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"commits"`
}

// author is the author of a review or a comment. GitHub gives null for a
// deleted account.
type author struct {
	Login string `json:"login"`
}

// writerAssociations are the author associations of a person who can push to
// the repo. A COLLABORATOR can have read access only, so this list can count
// a person who cannot push. Each other association, such as CONTRIBUTOR or
// NONE, is not a writer.
var writerAssociations = map[string]bool{"OWNER": true, "MEMBER": true, "COLLABORATOR": true}

// commentReview is the review that a review comment is part of.
type commentReview struct {
	AuthorCanPushToRepository bool `json:"authorCanPushToRepository"`
}

// isWriter is true when the author of a review comment can push to the repo.
// When the comment has a review, the push access of the review author is the
// answer. When it has no review, [writerAssociations] gives the answer from
// the association of the comment author.
func isWriter(review *commentReview, association string) bool {
	if review != nil {
		return review.AuthorCanPushToRepository
	}
	return writerAssociations[association]
}

// ghostLogin is the login that GitHub shows for a deleted account.
const ghostLogin = "ghost"

// loginOf is the login of an author, or [ghostLogin] for a deleted account.
func loginOf(a *author) string {
	if a == nil || a.Login == "" {
		return ghostLogin
	}
	return a.Login
}

// checkNode is a CheckRun or a StatusContext.
type checkNode struct {
	Typename    string     `json:"__typename"`
	Name        string     `json:"name"`
	Status      string     `json:"status"`
	Conclusion  string     `json:"conclusion"`
	DetailsURL  string     `json:"detailsUrl"`
	StartedAt   *time.Time `json:"startedAt"`
	CompletedAt *time.Time `json:"completedAt"`
	IsRequired  bool       `json:"isRequired"`
	CheckSuite  *struct {
		WorkflowRun *struct {
			DatabaseID int64 `json:"databaseId"`
			Workflow   struct {
				Name string `json:"name"`
			} `json:"workflow"`
		} `json:"workflowRun"`
	} `json:"checkSuite"`
	Context   string `json:"context"`
	State     string `json:"state"`
	TargetURL string `json:"targetUrl"`
}

// Fetch asks GitHub about branches of one repo. The result has an entry for
// each branch. Fetch runs one query, and a second one when a branch has an
// open PR. Each gh call stops after 15 seconds, or when ctx ends.
//
// When only the second query fails, Fetch returns its error with the
// branches that need nothing from it: each branch with no PR, or with a
// merged or closed PR. A branch with an open PR is not in that result.
func (c *Client) Fetch(ctx context.Context, repo Repo, branches []string) (map[string]Branch, error) {
	out := make(map[string]Branch, len(branches))
	if len(branches) == 0 {
		return out, nil
	}
	vars := map[string]any{"owner": repo.Owner, "name": repo.Name}
	var params, fields strings.Builder
	for i, b := range branches {
		fmt.Fprintf(&params, ", $h%d: String!, $q%d: String!", i, i)
		fmt.Fprintf(&fields, prFields, i, prsPerHead)
		vars[fmt.Sprintf("h%d", i)] = b
		vars[fmt.Sprintf("q%d", i)] = "refs/heads/" + b
	}
	var first struct {
		Repository map[string]json.RawMessage `json:"repository"`
	}
	if err := c.query(ctx, fmt.Sprintf(prQuery, params.String(), fields.String()), vars, &first); err != nil {
		return nil, err
	}

	var open []string // the branches with an open PR, in order
	for i, b := range branches {
		var prs struct {
			Nodes []prNode `json:"nodes"`
		}
		var ref *struct{}
		if err := decodeAlias(first.Repository, fmt.Sprintf("pr%d", i), &prs); err != nil {
			return nil, err
		}
		if err := decodeAlias(first.Repository, fmt.Sprintf("ref%d", i), &ref); err != nil {
			return nil, err
		}
		br := Branch{PR: pick(prs.Nodes), Pushed: ref != nil}
		if br.PR != nil && br.PR.State == "OPEN" {
			open = append(open, b)
		}
		out[b] = br
	}
	if len(open) == 0 {
		return out, nil
	}

	vars = map[string]any{"owner": repo.Owner, "name": repo.Name}
	params.Reset()
	fields.Reset()
	for i, b := range open {
		compare := ""
		if out[b].Pushed {
			compare = fmt.Sprintf(compareField, i)
			fmt.Fprintf(&params, ", $h%d: String!", i)
			vars[fmt.Sprintf("h%d", i)] = b
		}
		fmt.Fprintf(&params, ", $n%d: Int!", i)
		fmt.Fprintf(&fields, detailFields, i, maxNodes, compare, CommentsPerThread)
		vars[fmt.Sprintf("n%d", i)] = out[b].PR.Number
	}
	var second struct {
		Repository map[string]json.RawMessage `json:"repository"`
	}
	details := make([]detailNode, len(open))
	err := c.query(ctx, fmt.Sprintf(detailQuery, params.String(), fields.String()), vars, &second)
	for i := 0; err == nil && i < len(open); i++ {
		err = decodeAlias(second.Repository, fmt.Sprintf("p%d", i), &details[i])
	}
	if err != nil {
		for _, b := range open {
			delete(out, b)
		}
		return out, err
	}
	for i, b := range open {
		addDetails(out[b].PR, details[i])
	}
	return out, nil
}

// decodeAlias decodes the field of an alias in a GraphQL answer.
func decodeAlias(fields map[string]json.RawMessage, alias string, out any) error {
	raw, ok := fields[alias]
	if !ok {
		return fmt.Errorf("%w: the answer of GitHub has no %s", ErrOffline, alias)
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("%w: read %s: %v", ErrOffline, alias, err)
	}
	return nil
}

// pick returns the PR of a branch from its PRs, newest first. An open PR
// wins. A PR from a fork does not count: a fork can have a branch with the
// same name.
func pick(nodes []prNode) *PR {
	var chosen *prNode
	for i := range nodes {
		n := &nodes[i]
		if n.IsCrossRepository {
			continue
		}
		if chosen == nil || (n.State == "OPEN" && chosen.State != "OPEN") {
			chosen = n
		}
	}
	if chosen == nil {
		return nil
	}
	pr := &PR{
		Number: chosen.Number, Title: chosen.Title, URL: chosen.URL, State: chosen.State, Draft: chosen.IsDraft,
		Mergeable: chosen.Mergeable, MergeState: chosen.MergeStateStatus, ReviewDecision: chosen.ReviewDecision,
		InMergeQueue: chosen.IsInMergeQueue, Base: chosen.BaseRefName, Head: chosen.HeadRefName, HeadOID: chosen.HeadRefOid,
		MergedAt: chosen.MergedAt, ClosedAt: chosen.ClosedAt, Commits: chosen.Commits.TotalCount,
		FailedChecks: []Check{}, PassedChecks: []Check{}, ChangeRequests: []Review{}, ReviewThreads: []ReviewThread{},
	}
	if chosen.MergeQueueEntry != nil {
		pr.QueuePosition = chosen.MergeQueueEntry.Position
	}
	return pr
}

// addDetails adds the counts of the second query to an open PR.
func addDetails(pr *PR, d detailNode) {
	if d.BaseRef != nil && d.BaseRef.Compare != nil {
		pr.BehindBase = d.BaseRef.Compare.BehindBy
	}
	for _, r := range d.LatestOpinionatedReviews.Nodes {
		switch r.State {
		case "APPROVED":
			pr.Approvals++
		case "CHANGES_REQUESTED":
			pr.ChangeRequests = append(pr.ChangeRequests, Review{ID: r.ID, Author: loginOf(r.Author), Body: r.Body, URL: r.URL})
		}
	}
	for _, t := range d.ReviewThreads.Nodes {
		if t.IsResolved {
			continue
		}
		pr.Comments++
		thread := ReviewThread{ID: t.ID, Path: t.Path, Comments: []ReviewComment{}}
		if t.Line != nil {
			thread.Line = *t.Line
		}
		for _, c := range t.Comments.Nodes {
			writer := isWriter(c.PullRequestReview, c.AuthorAssociation)
			thread.Comments = append(thread.Comments, ReviewComment{Author: loginOf(c.Author), Writer: writer, Body: c.Body, URL: c.URL})
		}
		if len(thread.Comments) > 0 {
			thread.URL = thread.Comments[0].URL
		}
		pr.ReviewThreads = append(pr.ReviewThreads, thread)
	}
	if len(d.Commits.Nodes) == 0 || d.Commits.Nodes[0].Commit.StatusCheckRollup == nil {
		return
	}
	rollup := d.Commits.Nodes[0].Commit.StatusCheckRollup
	pr.Checks.State = rollup.State
	pr.Checks.Total = rollup.Contexts.TotalCount
	for _, n := range rollup.Contexts.Nodes {
		o := outcome(n)
		if n.IsRequired {
			pr.Checks.Required++
			if o == passed {
				pr.Checks.RequiredPassed++
			}
		}
		switch o {
		case passed:
			pr.Checks.Passed++
			pr.PassedChecks = append(pr.PassedChecks, checkOf(n))
		case failed:
			pr.Checks.Failed++
			pr.FailedChecks = append(pr.FailedChecks, checkOf(n))
		case running:
			pr.Checks.Running++
		case waiting:
			pr.Checks.Waiting++
		}
	}
}

type checkOutcome int

const (
	// other is a check that counts only in the total, such as a cancelled run.
	other checkOutcome = iota
	passed
	failed
	running
	waiting
)

// outcome sorts a check. A failure is one of the states that the stage rule
// names: FAILURE, ERROR, TIMED_OUT, and STARTUP_FAILURE. A wait for a person
// is WAITING or ACTION_REQUIRED.
func outcome(n checkNode) checkOutcome {
	if n.Typename == "StatusContext" {
		switch n.State {
		case "SUCCESS":
			return passed
		case "FAILURE", "ERROR":
			return failed
		case "PENDING", "EXPECTED":
			return running
		}
		return other
	}
	switch n.Status {
	case "COMPLETED":
	case "WAITING":
		return waiting
	default: // QUEUED, IN_PROGRESS, PENDING, REQUESTED
		return running
	}
	switch n.Conclusion {
	case "SUCCESS", "NEUTRAL", "SKIPPED":
		return passed
	case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE":
		return failed
	case "ACTION_REQUIRED":
		return waiting
	}
	return other
}

// checkOf returns the check that the answer of GitHub describes.
func checkOf(n checkNode) Check {
	if n.Typename == "StatusContext" {
		return Check{Name: n.Context, URL: n.TargetURL, Required: n.IsRequired}
	}
	c := Check{Name: n.Name, URL: n.DetailsURL, Required: n.IsRequired}
	if s := n.CheckSuite; s != nil && s.WorkflowRun != nil {
		c.RunID = s.WorkflowRun.DatabaseID
		if s.WorkflowRun.Workflow.Name != "" {
			c.Name = s.WorkflowRun.Workflow.Name + " / " + n.Name
		}
	}
	if n.StartedAt != nil && n.CompletedAt != nil {
		c.Duration = max(0, int(n.CompletedAt.Sub(*n.StartedAt).Seconds()))
	}
	return c
}
