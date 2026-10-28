// Package intake lists the work that a plot can start runs from: the open
// issues of its Linear team and project links, the open issues of its GitHub
// repos, and the open tickets of its wayfinder maps.
package intake

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/wayfinder"
)

// The kinds of a source. They are also the kinds of a run's source.
const (
	Linear = "linear"
	GitHub = "github"
	Map    = "map"
)

// Source is one place that the items come from: a Linear team or project
// link, a GitHub repo of the plot, or a map in the links of the plot.
type Source struct {
	Kind string `json:"kind"`
	// Label is the repo, such as "example/widgets", or the label of the link.
	Label string `json:"label"`
	// Error says why Loam could not read the source, or is "".
	Error string `json:"error"`
}

// Item is one issue or ticket.
type Item struct {
	Source string `json:"source"`
	// Key is the issue or ticket, such as "#48", "example/widgets#48", or
	// "map 135". It is the key of a run that starts from the item.
	Key    string `json:"key"`
	Title  string `json:"title"`
	Status string `json:"status"`
	// Priority is the Linear priority, such as High, or "".
	Priority string   `json:"priority"`
	Labels   []string `json:"labels"`
	// URL is the web page of an issue, or the path of a ticket file. It is
	// what loam run start takes as --link or --ticket.
	URL string `json:"url"`
	// UpdatedAt is the last change on GitHub, or "" for a ticket.
	UpdatedAt string `json:"updated_at"`
	// RunID is the newest run that started from the item, or "".
	RunID string `json:"run_id"`
	// Repo is the ID of the repo of the plot that a GitHub issue belongs
	// to, or "" for a Linear issue and a ticket.
	Repo string `json:"repo"`
	// Text is the first 1200 characters of the description, the body, or the
	// ticket text after its title line, or "".
	Text string `json:"text"`
	// Branch is the branch name that Linear gives the issue, or "".
	Branch string `json:"branch"`
	// CreatedAt is when the issue was made, or the change time of a ticket
	// file.
	CreatedAt string `json:"created_at"`
	// InCycle is true for a Linear issue in the active cycle of its team.
	InCycle bool `json:"in_cycle"`
	// AssignedToMe is true for an issue that is assigned to the person of
	// the Linear key or the gh user. It is false for a ticket.
	AssignedToMe bool `json:"assigned_to_me"`
	// Assignee is the name of the Linear assignee, or the logins of the
	// GitHub assignees, such as "ada, sam". It is "" for no assignee and for
	// a ticket.
	Assignee string `json:"assignee"`
	// InProgress is true for a Linear issue whose state type is started.
	InProgress bool `json:"in_progress"`
	// Milestone is the project milestone of a Linear issue, or "".
	Milestone string `json:"milestone"`
	// MilestoneOrder is the place of the milestone in its Linear project, or
	// 0 for no milestone.
	MilestoneOrder float64 `json:"milestone_order"`
}

// textLimit is how many characters of text an item keeps.
const textLimit = 1200

// clip trims the text and keeps its first textLimit characters.
func clip(text string) string {
	text = strings.TrimSpace(text)
	if r := []rune(text); len(r) > textLimit {
		text = strings.TrimSpace(string(r[:textLimit]))
	}
	return text
}

// Result is the intake of a plot.
type Result struct {
	PlotID  string   `json:"plot_id"`
	Sources []Source `json:"sources"`
	Items   []Item   `json:"items"`
}

// List reads the intake of the plot: Linear issues, then GitHub issues, each
// the newest change first, then map tickets in number order. A source that Loam cannot read
// has its error, and the other sources still show.
func List(ctx context.Context, s *store.Store, plotID string) (*Result, error) {
	plot, err := s.GetPlot(plotID)
	if err != nil {
		return nil, err
	}
	runs, err := s.ListRuns(plot.ID)
	if err != nil {
		return nil, err
	}
	res := &Result{PlotID: plot.ID, Sources: []Source{}, Items: []Item{}}
	// The key is read once, at the first Linear link.
	var lin *linear.Client
	var linErr error
	for _, l := range plot.Links {
		scope, ok := linear.ParseScope(l.Target)
		if !ok {
			continue
		}
		if lin == nil && linErr == nil {
			lin, linErr = linear.FromKeychain()
		}
		src := Source{Kind: Linear, Label: l.Label}
		var list []linear.Issue
		err := linErr
		if err == nil {
			list, err = lin.Issues(ctx, scope)
		}
		if err != nil {
			src.Error = err.Error()
		}
		res.Sources = append(res.Sources, src)
		for _, i := range list {
			res.Items = append(res.Items, Item{
				Source: Linear, Key: i.Key, Title: i.Title, Status: i.State, Priority: i.Priority,
				Labels: i.Labels, URL: i.URL, UpdatedAt: i.UpdatedAt, Text: clip(i.Description), Branch: i.Branch,
				CreatedAt: i.CreatedAt, InCycle: i.InCycle, AssignedToMe: i.AssignedToMe,
				Assignee: i.Assignee, InProgress: i.InProgress, Milestone: i.Milestone, MilestoneOrder: i.MilestoneOrder,
			})
		}
	}
	client, clientErr := github.NewClient()
	// The gh user is read once, at the first repo with an issue.
	var login string
	loginRead := false
	seen := map[github.Repo]bool{}
	for _, r := range plot.Repos {
		web, ok := gitremote.Origin(r.Path)
		if !ok {
			continue
		}
		repo, ok := github.ParseRepo(web)
		if !ok || seen[repo] {
			continue
		}
		seen[repo] = true
		src := Source{Kind: GitHub, Label: repo.Owner + "/" + repo.Name}
		var list []github.Issue
		err := clientErr
		if err == nil {
			list, err = client.Issues(ctx, repo)
		}
		if err != nil {
			src.Error = err.Error()
		}
		res.Sources = append(res.Sources, src)
		for _, i := range list {
			if !loginRead && len(i.Assignees) > 0 {
				loginRead = true
				login, _ = client.Login(ctx)
			}
			res.Items = append(res.Items, Item{
				Source: GitHub, Key: linkkind.IssueKey(i.URL, web), Title: i.Title, Status: "Open",
				Labels: i.Labels, URL: i.URL, UpdatedAt: i.UpdatedAt, Repo: r.ID,
				Text: clip(i.Body), CreatedAt: i.CreatedAt, AssignedToMe: login != "" && slices.Contains(i.Assignees, login),
				Assignee: strings.Join(i.Assignees, ", "),
			})
		}
	}
	for _, l := range plot.Links {
		path := linkkind.Expand(l.Target)
		if !linkkind.IsLocal(l.Target) || !wayfinder.IsMap(path) {
			continue
		}
		src := Source{Kind: Map, Label: l.Label}
		tickets, err := wayfinder.Tickets(path)
		if err != nil {
			src.Error = err.Error()
		}
		res.Sources = append(res.Sources, src)
		for _, t := range tickets {
			res.Items = append(res.Items, Item{
				Source: Map, Key: t.Key, Title: t.Title, Status: t.Status, Labels: []string{}, URL: t.Path,
				Text: clip(t.Text), CreatedAt: t.Modified.UTC().Format(time.RFC3339),
			})
		}
	}
	// The runs are newest first, so the first match is the newest run.
	for i := range res.Items {
		for _, r := range runs {
			if r.Source != nil && r.Source.URL == res.Items[i].URL {
				res.Items[i].RunID = r.ID
				break
			}
		}
	}
	return res, nil
}
