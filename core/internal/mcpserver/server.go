// Package mcpserver is the stdio MCP server behind `loam mcp`. It gives a
// Claude session the tools: three read tools, two worktree tools, and the write tools.
//
// One server process serves one Claude Code session. The process remembers the
// item versions that its last get_plot returned for each plot. A write passes
// those versions to the store as expectations, so a stale write fails and
// Claude never handles a version number.
package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"strings"
	"sync"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Options configure a server. Only Store is required.
type Options struct {
	Store *store.Store
	// PID is the parent process ID, which is the Claude Code process. The
	// default is os.Getppid().
	PID int
	// Getenv reads LOAM_PLOT and CLAUDE_CODE_SESSION_ID. The default is os.Getenv.
	Getenv func(string) string
	// Version is the server version that the MCP handshake reports.
	Version string
}

// Server holds the state of one MCP server process.
type Server struct {
	st     *store.Store
	pid    int
	getenv func(string) string

	mu       sync.Mutex
	versions map[string]map[string]int64 // plot ID -> item -> version
}

// New builds the MCP server with its tools registered.
func New(o Options) *mcp.Server {
	s := &Server{st: o.Store, pid: o.PID, getenv: o.Getenv, versions: map[string]map[string]int64{}}
	if s.pid == 0 {
		s.pid = os.Getppid()
	}
	if s.getenv == nil {
		s.getenv = os.Getenv
	}
	v := o.Version
	if v == "" {
		v = "dev"
	}
	srv := mcp.NewServer(&mcp.Implementation{Name: "loam", Version: v}, nil)
	s.register(srv)
	s.registerUndo(srv)
	s.registerWorktrees(srv)
	return srv
}

// Run serves the MCP protocol on stdin and stdout until the client leaves.
// Logs must go to stderr, because stdout carries the protocol.
func Run(ctx context.Context, o Options) error {
	return New(o).Run(ctx, &mcp.StdioTransport{})
}

// resolvePlot returns the plot ID to use: the argument, else LOAM_PLOT.
func (s *Server) resolvePlot(arg string) (string, error) {
	id := arg
	if id == "" {
		id = s.getenv("LOAM_PLOT")
	}
	if id == "" {
		return "", errors.New("no plot given and LOAM_PLOT is not set: call list_plots, then pass the plot ID in the plot argument")
	}
	return id, nil
}

// loadPlot reads a plot by ID. A name or a wrong ID gets a message that
// points Claude at list_plots.
func (s *Server) loadPlot(id string) (store.Plot, error) {
	p, err := s.st.GetPlot(id)
	if errors.Is(err, store.ErrNotFound) {
		return p, fmt.Errorf("no plot has the ID %q: call list_plots and pass an ID, not a name", id)
	}
	return p, err
}

// actor finds the current session. The store record for the parent PID wins,
// because /clear does not restart this process and the environment goes stale.
func (s *Server) actor() (store.Actor, error) {
	id, found, err := s.st.SessionForPID(s.pid)
	if err != nil {
		return store.Actor{}, err
	}
	if !found {
		id = s.getenv("CLAUDE_CODE_SESSION_ID")
	}
	if id == "" {
		return store.Actor{Kind: store.ActorSession}, nil
	}
	return s.st.SessionActor(id)
}

func (s *Server) remember(p store.Plot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.versions[p.ID] = maps.Clone(p.Versions)
}

// expectations returns the remembered versions of the named items. It fails
// when Claude has not read the plot, or has not seen an item.
func (s *Server) expectations(plotID string, items ...string) (map[string]int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	known, ok := s.versions[plotID]
	if !ok {
		return nil, fmt.Errorf("call get_plot for plot %s before you change it", plotID)
	}
	exp := make(map[string]int64, len(items))
	for _, it := range items {
		v, ok := known[it]
		if !ok {
			return nil, fmt.Errorf("%s is not in the last get_plot result for plot %s: call get_plot again", it, plotID)
		}
		exp[it] = v
	}
	return exp, nil
}

// afterWrite updates the remembered versions for the items that the write
// set or removed. Other items keep the version that Claude read.
func (s *Server) afterWrite(res *store.Result, set []string, removed []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	known := s.versions[res.Plot.ID]
	if known == nil {
		return
	}
	for _, it := range append(append([]string{}, set...), res.Added...) {
		if v, ok := res.Plot.Versions[it]; ok {
			known[it] = v
		}
	}
	for _, it := range removed {
		delete(known, it)
	}
}

// refresh sets the remembered version of items that Claude has already read
// and that a write changed as a side effect, such as the old main repo.
func (s *Server) refresh(res *store.Result, items ...string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	known := s.versions[res.Plot.ID]
	for _, it := range items {
		if _, ok := known[it]; !ok {
			continue
		}
		if v, ok := res.Plot.Versions[it]; ok {
			known[it] = v
		}
	}
}

// write runs one change: it checks the get-before-write rule, applies the
// edits as one change, and rewrites the seed. A failed seed write is a warning.
func (s *Server) write(plotArg string, items []string, removed []string, edits []store.Edit) (*store.Result, error) {
	plotID, err := s.resolvePlot(plotArg)
	if err != nil {
		return nil, err
	}
	exp, err := s.expectations(plotID, items...)
	if err != nil {
		return nil, err
	}
	actor, err := s.actor()
	if err != nil {
		return nil, err
	}
	res, err := s.st.Apply(store.Change{PlotID: plotID, Actor: actor, Expect: exp, Edits: edits})
	if err != nil {
		return nil, err
	}
	s.afterWrite(res, items, removed)
	seed.AfterChange(s.st, res)
	return res, nil
}

// reply wraps a value as a JSON text result.
func reply(v any) (*mcp.CallToolResult, any, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, nil, err
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(b)}}}, nil, nil
}

// fail turns an error into a tool error. A stale write returns the current
// values and tells Claude to read again.
func fail(err error) (*mcp.CallToolResult, any, error) {
	var stale *store.StaleError
	text := err.Error()
	if errors.As(err, &stale) {
		b, _ := json.MarshalIndent(stale.Items, "", "  ")
		text = fmt.Sprintf("%s. Nothing was saved. Call get_plot to read the current plot, then try again. Current values:\n%s", stale.Error(), b)
	}
	return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: text}}}, nil, nil
}

// plotView is the plot as Claude sees it. It has no versions and no revision.
type plotView struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	What     string     `json:"what"`
	Why      string     `json:"why"`
	Where    string     `json:"where_it_stands"`
	Archived bool       `json:"archived"`
	Links    []linkView `json:"links"`
	Repos    []repoView `json:"repos"`
}

type linkView struct {
	ID     string `json:"id"`
	Label  string `json:"label"`
	Target string `json:"target"`
	Note   string `json:"note"`
	// Kind is notion, linear, github, url, path, or vault.
	Kind string `json:"kind"`
	// Exists is set for a path or vault link: whether the path exists.
	Exists *bool `json:"exists,omitempty"`
}

type repoView struct {
	ID    string   `json:"id"`
	Path  string   `json:"path"`
	Note  string   `json:"note"`
	Main  bool     `json:"main"`
	Setup string   `json:"setup,omitempty"`
	Copy  []string `json:"copy,omitempty"`
}

func viewOf(p store.Plot) plotView {
	v := plotView{ID: p.ID, Name: p.Name, What: p.What, Why: p.Why, Where: p.Where, Archived: p.Archived,
		Links: make([]linkView, len(p.Links)), Repos: make([]repoView, len(p.Repos))}
	vaults := linkkind.Vaults()
	for i, l := range p.Links {
		info := linkkind.Classify(l.Target, vaults)
		v.Links[i] = linkView{ID: l.ID, Label: l.Label, Target: l.Target, Note: l.Note, Kind: info.Kind}
		if info.Local {
			exists := info.Exists
			v.Links[i].Exists = &exists
		}
	}
	for i, r := range p.Repos {
		v.Repos[i] = repoView{r.ID, r.Path, r.Note, r.Main, r.Setup, r.Copy}
	}
	return v
}

type writeOut struct {
	ChangeID int64    `json:"change_id"`
	LinkID   string   `json:"link_id,omitempty"`
	RepoID   string   `json:"repo_id,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

func linkID(res *store.Result) string { return addedID(res, "link:") }

func repoID(res *store.Result) string { return addedID(res, "repo:") }

func addedID(res *store.Result, prefix string) string {
	for _, it := range res.Added {
		if strings.HasPrefix(it, prefix) {
			return it[len(prefix):]
		}
	}
	return ""
}

// Tool arguments. The plot field is the same in every tool.
type plotArg struct {
	Plot string `json:"plot,omitempty" jsonschema:"plot ID. Optional: the default is the plot of this session. Use list_plots to find an ID."`
}

type getPlotIn struct{ plotArg }

type getChangesIn struct {
	plotArg
	Limit int `json:"limit,omitempty" jsonschema:"most changes to return. Default 20."`
}

type addLinkIn struct {
	plotArg
	Label  string `json:"label,omitempty" jsonschema:"short name of the link. Optional: with no label, the link takes one from the target, such as the file name or the issue ID."`
	Target string `json:"target" jsonschema:"a URL, or an absolute path that starts with / or ~"`
	Note   string `json:"note,omitempty" jsonschema:"one line about why the link matters"`
}

type updateLinkIn struct {
	plotArg
	LinkID string  `json:"link_id" jsonschema:"ID of the link, from get_plot"`
	Label  *string `json:"label,omitempty" jsonschema:"new label"`
	Target *string `json:"target,omitempty" jsonschema:"new target"`
	Note   *string `json:"note,omitempty" jsonschema:"new note"`
}

type removeLinkIn struct {
	plotArg
	LinkID string `json:"link_id" jsonschema:"ID of the link, from get_plot"`
}

type setWhatWhyIn struct {
	plotArg
	What *string `json:"what,omitempty" jsonschema:"new What text"`
	Why  *string `json:"why,omitempty" jsonschema:"new Why text"`
}

type setWhereIn struct {
	plotArg
	Text string `json:"text" jsonschema:"new Where it stands text"`
}

func readOnly(title string) *mcp.ToolAnnotations {
	f := false
	return &mcp.ToolAnnotations{Title: title, ReadOnlyHint: true, OpenWorldHint: &f}
}

func addOnly(title string) *mcp.ToolAnnotations {
	f := false
	return &mcp.ToolAnnotations{Title: title, DestructiveHint: &f, OpenWorldHint: &f}
}

func changes(title string) *mcp.ToolAnnotations {
	f := false
	return &mcp.ToolAnnotations{Title: title, OpenWorldHint: &f}
}

const plotNote = " The plot argument is an ID. If you omit it, the tool uses the plot of this session."

type listPlotsIn struct {
	Archived bool `json:"archived,omitempty" jsonschema:"set to true to list the archived plots, and no others. The default lists the plots that are not archived."`
}

func (s *Server) register(srv *mcp.Server) {
	s.registerPlotRepo(srv)
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "list_plots",
		Description: "List every plot with its ID, name, and What part, in the stored order. Use it to find a plot ID. Archived plots are not in the list. Set archived to true to list the archived plots instead.",
		Annotations: readOnly("List plots"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in listPlotsIn) (*mcp.CallToolResult, any, error) {
		all, err := s.st.ListPlots()
		if err != nil {
			return fail(err)
		}
		plots := store.FilterPlots(all, in.Archived)
		type row struct {
			ID       string `json:"id"`
			Name     string `json:"name"`
			What     string `json:"what"`
			Archived bool   `json:"archived"`
		}
		rows := make([]row, len(plots))
		for i, p := range plots {
			rows[i] = row{p.ID, p.Name, p.What, p.Archived}
		}
		return reply(map[string]any{"plots": rows})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "get_plot",
		Description: "Get the full plot: name, What, Why, Where it stands, links, and repos. Each link has a kind (notion, linear, github, url, path, or vault). A path or vault link also says whether the path exists. Call it before any write to the plot. A write fails if the plot changed after your last get_plot." + plotNote,
		Annotations: readOnly("Get a plot"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in getPlotIn) (*mcp.CallToolResult, any, error) {
		id, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		p, err := s.loadPlot(id)
		if err != nil {
			return fail(err)
		}
		s.remember(p)
		return reply(viewOf(p))
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "get_changes",
		Description: "Get the change log of one plot, newest first. Each change has an ID, a time, an actor, the changed fields with old and new values, and undo_of (the ID of the change that this change reverted, or null)." + plotNote,
		Annotations: readOnly("Get changes"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in getChangesIn) (*mcp.CallToolResult, any, error) {
		id, err := s.resolvePlot(in.Plot)
		if err != nil {
			return fail(err)
		}
		if _, err := s.loadPlot(id); err != nil {
			return fail(err)
		}
		limit := in.Limit
		if limit <= 0 {
			limit = 20
		}
		cs, err := s.st.ListChanges(store.ChangeQuery{PlotID: id, Limit: limit, Newest: true})
		if err != nil {
			return fail(err)
		}
		if cs == nil {
			cs = []store.ChangeRecord{}
		}
		return reply(map[string]any{"changes": cs})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "add_link",
		Description: "Add a link to the plot. A link has a target (a URL or an absolute path), a label, and an optional note. With no label, the link takes one from the target. Call get_plot first." + plotNote,
		Annotations: addOnly("Add a link"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in addLinkIn) (*mcp.CallToolResult, any, error) {
		res, err := s.write(in.Plot, nil, nil, []store.Edit{{Op: store.OpAddLink,
			Label: store.S(in.Label), Target: store.S(in.Target), Note: store.S(in.Note)}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, LinkID: linkID(res), Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "update_link",
		Description: "Change the label, target, or note of a link. Pass only the fields to change. Call get_plot first." + plotNote,
		Annotations: changes("Update a link"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in updateLinkIn) (*mcp.CallToolResult, any, error) {
		if in.LinkID == "" {
			return fail(errors.New("link_id is required"))
		}
		if in.Label == nil && in.Target == nil && in.Note == nil {
			return fail(errors.New("give at least one of label, target, or note"))
		}
		item := store.LinkItem(in.LinkID)
		res, err := s.write(in.Plot, []string{item}, nil, []store.Edit{{Op: store.OpUpdateLink, Item: item,
			Label: in.Label, Target: in.Target, Note: in.Note}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "remove_link",
		Description: "Remove a link from the plot. Call get_plot first." + plotNote,
		Annotations: changes("Remove a link"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in removeLinkIn) (*mcp.CallToolResult, any, error) {
		if in.LinkID == "" {
			return fail(errors.New("link_id is required"))
		}
		item := store.LinkItem(in.LinkID)
		res, err := s.write(in.Plot, []string{item}, []string{item}, []store.Edit{{Op: store.OpRemoveLink, Item: item}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_what_why",
		Description: "Set the What text, the Why text, or both. Pass only the parts to change. Call get_plot first." + plotNote,
		Annotations: changes("Set What and Why"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in setWhatWhyIn) (*mcp.CallToolResult, any, error) {
		var items []string
		var edits []store.Edit
		if in.What != nil {
			items = append(items, store.ItemWhat)
			edits = append(edits, store.Edit{Op: store.OpSet, Item: store.ItemWhat, Value: *in.What})
		}
		if in.Why != nil {
			items = append(items, store.ItemWhy)
			edits = append(edits, store.Edit{Op: store.OpSet, Item: store.ItemWhy, Value: *in.Why})
		}
		if len(edits) == 0 {
			return fail(errors.New("give at least one of what or why"))
		}
		res, err := s.write(in.Plot, items, nil, edits)
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_where_it_stands",
		Description: "Set the Where it stands text: what is done, what is next, and what blocks the work. Call it when the work moves on. Call get_plot first." + plotNote,
		Annotations: changes("Set Where it stands"),
	}, func(_ context.Context, _ *mcp.CallToolRequest, in setWhereIn) (*mcp.CallToolResult, any, error) {
		res, err := s.write(in.Plot, []string{store.ItemWhere}, nil, []store.Edit{{Op: store.OpSet, Item: store.ItemWhere, Value: in.Text}})
		if err != nil {
			return fail(err)
		}
		return reply(writeOut{ChangeID: res.ChangeID, Warnings: res.Warnings})
	})
}
