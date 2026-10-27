package github

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
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
}

// Issues returns the open issues of the repo, the most recently updated first
// (gh issue list). Pull requests are not in the list.
func (c *Client) Issues(ctx context.Context, repo Repo) ([]Issue, error) {
	out, err := c.run(ctx, ghTimeout, nil, "issue", "list", "--repo", repo.flag(), "--state", "open",
		"--limit", strconv.Itoa(issueLimit), "--json", "number,title,url,labels,updatedAt")
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
		issues[i] = Issue{Number: n.Number, Title: n.Title, URL: n.URL, Labels: labels, UpdatedAt: n.UpdatedAt}
	}
	return issues, nil
}
