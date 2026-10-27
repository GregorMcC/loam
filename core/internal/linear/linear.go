// Package linear reads issues from Linear, moves an issue to In Progress
// when a run starts from it, and attaches the PR of the run to the issue. It
// talks to the Linear GraphQL API with a personal API key.
package linear

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

// DefaultURL is the Linear GraphQL API.
const DefaultURL = "https://api.linear.app/graphql"

// requestTimeout stops a call that waits on the network.
const requestTimeout = 20 * time.Second

// responseLimit is the largest answer that Loam reads.
const responseLimit = 8 << 20

// issueLimit is how many open issues Loam reads for a scope.
const issueLimit = 100

var (
	// ErrBadKey means Linear refused the API key.
	ErrBadKey = errors.New("Linear refused the API key. Make a new personal API key in Linear, under Settings > Account > Security & access")
	// ErrOffline means Loam could not reach Linear.
	ErrOffline = errors.New("could not reach Linear")
)

// Scope is the issues that a plot link names: the issues of a team, or of a
// project.
type Scope struct {
	// Team is a team key, such as ENG, in upper case.
	Team string
	// Project is the short ID at the end of a project URL.
	Project string
}

// ParseScope returns the scope of a Linear team page, such as
// https://linear.app/acme/team/ENG/active, or a project page, such as
// https://linear.app/acme/project/loam-redesign-8f3a2b1c9d0e/overview. Any
// other target has no scope.
func ParseScope(target string) (Scope, bool) {
	u, err := url.Parse(strings.TrimSpace(target))
	if err != nil || !strings.EqualFold(u.Hostname(), "linear.app") {
		return Scope{}, false
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 3 || parts[2] == "" {
		return Scope{}, false
	}
	switch parts[1] {
	case "team":
		return Scope{Team: strings.ToUpper(parts[2])}, true
	case "project":
		slug := parts[2]
		if i := strings.LastIndex(slug, "-"); i >= 0 {
			slug = slug[i+1:]
		}
		return Scope{Project: slug}, true
	}
	return Scope{}, false
}

// Client calls the Linear API with one API key.
type Client struct {
	url  string
	key  string
	http *http.Client
}

// NewClient returns a client for the API at apiURL, usually [DefaultURL].
func NewClient(apiURL, key string) *Client {
	return &Client{url: apiURL, key: key, http: &http.Client{Timeout: requestTimeout}}
}

// Viewer is the person that the API key belongs to.
type Viewer struct {
	Name         string `json:"name"`
	Email        string `json:"email"`
	Organization string `json:"organization"`
}

// Viewer checks the key and returns its person and workspace.
func (c *Client) Viewer(ctx context.Context) (Viewer, error) {
	var out struct {
		Viewer struct {
			Name  string `json:"name"`
			Email string `json:"email"`
		} `json:"viewer"`
		Organization struct {
			Name string `json:"name"`
		} `json:"organization"`
	}
	if err := c.query(ctx, `query { viewer { name email } organization { name } }`, nil, &out); err != nil {
		return Viewer{}, err
	}
	return Viewer{Name: out.Viewer.Name, Email: out.Viewer.Email, Organization: out.Organization.Name}, nil
}

// Issue is an open issue.
type Issue struct {
	// Key is the identifier, such as ENG-523.
	Key   string
	Title string
	URL   string
	// State is the name of its workflow state, such as Todo.
	State string
	// Priority is Urgent, High, Medium, or Low, or "" for none.
	Priority  string
	Labels    []string
	UpdatedAt string
}

// Issues returns the open issues of the scope, the most recently updated
// first. An issue that is completed or canceled is not open.
func (c *Client) Issues(ctx context.Context, s Scope) ([]Issue, error) {
	filter := map[string]any{"state": map[string]any{"type": map[string]any{"nin": []string{"completed", "canceled"}}}}
	switch {
	case s.Team != "":
		filter["team"] = map[string]any{"key": map[string]any{"eq": s.Team}}
	case s.Project != "":
		filter["project"] = map[string]any{"slugId": map[string]any{"eq": s.Project}}
	default:
		return nil, errors.New("a Linear scope needs a team or a project")
	}
	var out struct {
		Issues struct {
			Nodes []struct {
				Identifier    string `json:"identifier"`
				Title         string `json:"title"`
				URL           string `json:"url"`
				PriorityLabel string `json:"priorityLabel"`
				UpdatedAt     string `json:"updatedAt"`
				State         struct {
					Name string `json:"name"`
				} `json:"state"`
				Labels struct {
					Nodes []struct {
						Name string `json:"name"`
					} `json:"nodes"`
				} `json:"labels"`
			} `json:"nodes"`
		} `json:"issues"`
	}
	q := fmt.Sprintf(`query($filter: IssueFilter) { issues(filter: $filter, first: %d, orderBy: updatedAt) {
  nodes { identifier title url priorityLabel updatedAt state { name } labels { nodes { name } } } } }`, issueLimit)
	if err := c.query(ctx, q, map[string]any{"filter": filter}, &out); err != nil {
		return nil, err
	}
	issues := make([]Issue, len(out.Issues.Nodes))
	for i, n := range out.Issues.Nodes {
		labels := make([]string, len(n.Labels.Nodes))
		for j, l := range n.Labels.Nodes {
			labels[j] = l.Name
		}
		priority := n.PriorityLabel
		if priority == "No priority" {
			priority = ""
		}
		issues[i] = Issue{Key: n.Identifier, Title: n.Title, URL: n.URL, State: n.State.Name, Priority: priority,
			Labels: labels, UpdatedAt: n.UpdatedAt}
	}
	return issues, nil
}

// workflowState is a state of the workflow of a team.
type workflowState struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Position float64 `json:"position"`
}

// notStarted are the state types of an issue that no one works on yet, and
// ended are the state types of an issue that is closed.
var (
	notStarted = []string{"triage", "backlog", "unstarted"}
	ended      = []string{"completed", "canceled"}
)

// Start moves the issue, such as ENG-523, to the first started state of its
// team, such as In Progress, and returns the name of that state. An issue
// that has started, or has ended, stays where it is, and Start returns "".
func (c *Client) Start(ctx context.Context, id string) (string, error) {
	return c.move(ctx, id, "started", func(from string) bool { return slices.Contains(notStarted, from) })
}

// Finish moves the issue to the first completed state of its team, such as
// Done, and returns the name of that state. An issue that has ended stays
// where it is, and Finish returns "".
func (c *Client) Finish(ctx context.Context, id string) (string, error) {
	return c.move(ctx, id, "completed", func(from string) bool { return !slices.Contains(ended, from) })
}

// move moves the issue to the first state of the type, by position, when
// the type of its state now passes from.
func (c *Client) move(ctx context.Context, id, to string, from func(string) bool) (string, error) {
	var out struct {
		Issue struct {
			State struct {
				Type string `json:"type"`
			} `json:"state"`
			Team struct {
				States struct {
					Nodes []workflowState `json:"nodes"`
				} `json:"states"`
			} `json:"team"`
		} `json:"issue"`
	}
	q := `query($id: String!, $type: String!) { issue(id: $id) { state { type }
  team { states(filter: { type: { eq: $type } }) { nodes { id name position } } } } }`
	if err := c.query(ctx, q, map[string]any{"id": id, "type": to}, &out); err != nil {
		return "", err
	}
	states := out.Issue.Team.States.Nodes
	if !from(out.Issue.State.Type) || len(states) == 0 {
		return "", nil
	}
	first := slices.MinFunc(states, func(a, b workflowState) int { return cmp.Compare(a.Position, b.Position) })
	var done struct {
		IssueUpdate struct {
			Success bool `json:"success"`
		} `json:"issueUpdate"`
	}
	m := `mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }`
	if err := c.query(ctx, m, map[string]any{"id": id, "state": first.ID}, &done); err != nil {
		return "", err
	}
	if !done.IssueUpdate.Success {
		return "", fmt.Errorf("Linear did not move %s to %s", id, first.Name)
	}
	return first.Name, nil
}

// Attach links url to the issue, such as ENG-523, with title as the name of
// the link. Linear shows the link on the issue.
func (c *Client) Attach(ctx context.Context, id, url, title string) error {
	var out struct {
		AttachmentLinkURL struct {
			Success bool `json:"success"`
		} `json:"attachmentLinkURL"`
	}
	m := `mutation($id: String!, $url: String!, $title: String) { attachmentLinkURL(issueId: $id, url: $url, title: $title) { success } }`
	if err := c.query(ctx, m, map[string]any{"id": id, "url": url, "title": title}, &out); err != nil {
		return err
	}
	if !out.AttachmentLinkURL.Success {
		return fmt.Errorf("Linear did not attach %s to %s", url, id)
	}
	return nil
}

// query sends one GraphQL request and decodes its data into out.
func (c *Client) query(ctx context.Context, query string, vars map[string]any, out any) error {
	body, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	// A personal API key goes in the header as it is, with no "Bearer".
	req.Header.Set("Authorization", c.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %v", ErrOffline, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, responseLimit))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrOffline, err)
	}
	var r struct {
		Data   json.RawMessage `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	jsonErr := json.Unmarshal(data, &r)
	var messages []string
	for _, e := range r.Errors {
		messages = append(messages, e.Message)
	}
	text := strings.Join(messages, "; ")
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden ||
		strings.Contains(strings.ToLower(text), "authenticat"):
		return ErrBadKey
	case len(messages) > 0:
		return fmt.Errorf("Linear: %s", text)
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("%w: HTTP %d", ErrOffline, resp.StatusCode)
	case jsonErr != nil:
		return fmt.Errorf("%w: Linear gave an answer that is not JSON: %v", ErrOffline, jsonErr)
	}
	if err := json.Unmarshal(r.Data, out); err != nil {
		return fmt.Errorf("Linear gave an answer that Loam cannot read: %w", err)
	}
	return nil
}
