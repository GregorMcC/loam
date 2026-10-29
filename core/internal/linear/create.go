package linear

import (
	"context"
	"errors"
	"fmt"
)

// Home is the place where a new issue goes: a team and, usually, a project.
type Home struct {
	// IssueID is the ID of the issue that [Client.HomeOfIssue] read, or "".
	IssueID   string
	TeamID    string
	ProjectID string
}

// HomeOfIssue returns the team and the project of the issue, such as
// ENG-523, and the ID of the issue. A new issue in that home is in the same
// project as the issue.
func (c *Client) HomeOfIssue(ctx context.Context, id string) (Home, error) {
	var out struct {
		Issue struct {
			ID   string `json:"id"`
			Team struct {
				ID string `json:"id"`
			} `json:"team"`
			Project *struct {
				ID string `json:"id"`
			} `json:"project"`
		} `json:"issue"`
	}
	q := `query HomeOfIssue($id: String!) { issue(id: $id) { id team { id } project { id } } }`
	if err := c.query(ctx, q, map[string]any{"id": id}, &out); err != nil {
		return Home{}, err
	}
	h := Home{IssueID: out.Issue.ID, TeamID: out.Issue.Team.ID}
	if out.Issue.Project != nil {
		h.ProjectID = out.Issue.Project.ID
	}
	if h.TeamID == "" {
		return Home{}, fmt.Errorf("Linear does not have the issue %s", id)
	}
	return h, nil
}

// HomeOfScope returns the home that a team or a project page names. The home
// of a project is its first team.
func (c *Client) HomeOfScope(ctx context.Context, s Scope) (Home, error) {
	switch {
	case s.Project != "":
		var out struct {
			Projects struct {
				Nodes []struct {
					ID    string `json:"id"`
					Teams struct {
						Nodes []struct {
							ID string `json:"id"`
						} `json:"nodes"`
					} `json:"teams"`
				} `json:"nodes"`
			} `json:"projects"`
		}
		q := `query HomeOfProject($filter: ProjectFilter) { projects(filter: $filter, first: 1) { nodes { id teams { nodes { id } } } } }`
		filter := map[string]any{"slugId": map[string]any{"eq": s.Project}}
		if err := c.query(ctx, q, map[string]any{"filter": filter}, &out); err != nil {
			return Home{}, err
		}
		if len(out.Projects.Nodes) == 0 || len(out.Projects.Nodes[0].Teams.Nodes) == 0 {
			return Home{}, fmt.Errorf("Linear does not have the project %s, or it has no team", s.Project)
		}
		p := out.Projects.Nodes[0]
		return Home{TeamID: p.Teams.Nodes[0].ID, ProjectID: p.ID}, nil
	case s.Team != "":
		var out struct {
			Teams struct {
				Nodes []struct {
					ID string `json:"id"`
				} `json:"nodes"`
			} `json:"teams"`
		}
		q := `query HomeOfTeam($filter: TeamFilter) { teams(filter: $filter, first: 1) { nodes { id } } }`
		filter := map[string]any{"key": map[string]any{"eq": s.Team}}
		if err := c.query(ctx, q, map[string]any{"filter": filter}, &out); err != nil {
			return Home{}, err
		}
		if len(out.Teams.Nodes) == 0 {
			return Home{}, fmt.Errorf("Linear does not have the team %s", s.Team)
		}
		return Home{TeamID: out.Teams.Nodes[0].ID}, nil
	}
	return Home{}, errors.New("a Linear scope needs a team or a project")
}

// NewIssue is an issue for [Client.CreateIssue] to make.
type NewIssue struct {
	Home
	Title string
	// Description is Markdown.
	Description string
}

// Created is an issue that [Client.CreateIssue] made.
type Created struct {
	ID  string
	Key string
	URL string
}

// CreateIssue makes an issue in the home, and returns it.
func (c *Client) CreateIssue(ctx context.Context, n NewIssue) (Created, error) {
	var out struct {
		IssueCreate struct {
			Success bool `json:"success"`
			Issue   struct {
				ID         string `json:"id"`
				Identifier string `json:"identifier"`
				URL        string `json:"url"`
			} `json:"issue"`
		} `json:"issueCreate"`
	}
	input := map[string]any{"teamId": n.TeamID, "title": n.Title, "description": n.Description}
	if n.ProjectID != "" {
		input["projectId"] = n.ProjectID
	}
	m := `mutation IssueCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }`
	if err := c.query(ctx, m, map[string]any{"input": input}, &out); err != nil {
		return Created{}, err
	}
	i := out.IssueCreate.Issue
	if !out.IssueCreate.Success || i.Identifier == "" {
		return Created{}, errors.New("Linear did not make the issue")
	}
	return Created{ID: i.ID, Key: i.Identifier, URL: i.URL}, nil
}

// Relate marks two issues as related. Each is the ID of an issue.
func (c *Client) Relate(ctx context.Context, issueID, relatedID string) error {
	var out struct {
		IssueRelationCreate struct {
			Success bool `json:"success"`
		} `json:"issueRelationCreate"`
	}
	m := `mutation($issue: String!, $related: String!) { issueRelationCreate(input: { issueId: $issue, relatedIssueId: $related, type: related }) { success } }`
	if err := c.query(ctx, m, map[string]any{"issue": issueID, "related": relatedID}, &out); err != nil {
		return err
	}
	if !out.IssueRelationCreate.Success {
		return errors.New("Linear did not relate the issues")
	}
	return nil
}
