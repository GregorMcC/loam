package github

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// issueLimit is how many open issues Loam reads from a repo, the newest first.
const issueLimit = 100

// Issue is an open issue of a repo.
type Issue struct {
	Number    int
	Title     string
	URL       string
	Labels    []string
	UpdatedAt string
	// Body is the whole body, which can be empty.
	Body      string
	CreatedAt string
	// Assignees are the logins of the people the issue is assigned to.
	Assignees []string
}

// Issues returns the open issues of the repo, the most recently updated first
// (gh issue list). Pull requests are not in the list.
func (c *Client) Issues(ctx context.Context, repo Repo) ([]Issue, error) {
	out, err := c.run(ctx, ghTimeout, nil, "issue", "list", "--repo", repo.flag(), "--state", "open",
		"--limit", strconv.Itoa(issueLimit), "--json", "number,title,url,labels,updatedAt,body,createdAt,assignees")
	if err != nil {
		return nil, readError(err)
	}
	var nodes []struct {
		Number int    `json:"number"`
		Title  string `json:"title"`
		URL    string `json:"url"`
		Labels []struct {
			Name string `json:"name"`
		} `json:"labels"`
		UpdatedAt string `json:"updatedAt"`
		CreatedAt string `json:"createdAt"`
		Body      string `json:"body"`
		Assignees []struct {
			Login string `json:"login"`
		} `json:"assignees"`
	}
	if err := json.Unmarshal(out, &nodes); err != nil {
		return nil, fmt.Errorf("%w: gh gave an answer that Loam cannot read: %v", ErrOffline, err)
	}
	issues := make([]Issue, len(nodes))
	for i, n := range nodes {
		labels := make([]string, len(n.Labels))
		for j, l := range n.Labels {
			labels[j] = l.Name
		}
		assignees := make([]string, len(n.Assignees))
		for j, a := range n.Assignees {
			assignees[j] = a.Login
		}
		issues[i] = Issue{Number: n.Number, Title: n.Title, URL: n.URL, Labels: labels, UpdatedAt: n.UpdatedAt,
			Body: n.Body, CreatedAt: n.CreatedAt, Assignees: assignees}
	}
	return issues, nil
}

// Login returns the login of the person that gh is signed in as
// (gh api user).
func (c *Client) Login(ctx context.Context) (string, error) {
	out, err := c.run(ctx, ghTimeout, nil, "api", "--hostname", host, "user", "--jq", ".login")
	if err != nil {
		return "", readError(err)
	}
	return strings.TrimSpace(string(out)), nil
}

// IssueText returns the title and the body of an issue, by its URL (gh issue
// view), with an empty line between them.
func (c *Client) IssueText(ctx context.Context, url string) (string, error) {
	out, err := c.run(ctx, ghTimeout, nil, "issue", "view", url, "--json", "title,body")
	if err != nil {
		return "", readError(err)
	}
	var issue struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	if err := json.Unmarshal(out, &issue); err != nil {
		return "", fmt.Errorf("%w: gh gave an answer that Loam cannot read: %v", ErrOffline, err)
	}
	return strings.TrimSpace(issue.Title + "\n\n" + issue.Body), nil
}
