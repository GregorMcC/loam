package run

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/worktree"
)

// shapeTimeout limits one draft. Claude reads the repo before it answers.
const shapeTimeout = 10 * time.Minute

// draftStepsMax is how many steps of one draft Loam records as draft events.
const draftStepsMax = 100

// issueTextMax is how much of the text of an issue a draft prompt keeps.
const issueTextMax = 20000

// draftingNote is the note of a run while Claude drafts it.
const draftingNote = "Claude is drafting the run"

// draftFields are the JSON Schema properties of one draft.
const draftFields = `
  "goal": {"type": "string"},
  "checks": {"type": "array", "items": {"type": "object", "additionalProperties": false,
   "required": ["name", "command"], "properties": {"name": {"type": "string"}, "command": {"type": "string"}}}},
  "assumptions": {"type": "array", "items": {"type": "string"}},
  "plan": {"type": "array", "items": {"type": "string"}},
  "size": {"type": "string"}`

// draftSchema is the JSON Schema of a draft, for claude -p --json-schema.
const draftSchema = `{"type": "object", "additionalProperties": false,
 "required": ["goal", "checks", "assumptions", "plan", "size"],
 "properties": {` + draftFields + `}}`

// splitSchema is the JSON Schema of a split draft: one draft for each repo
// that the issue needs changes in.
const splitSchema = `{"type": "object", "additionalProperties": false, "required": ["runs"],
 "properties": {"runs": {"type": "array", "minItems": 1, "items": {"type": "object", "additionalProperties": false,
 "required": ["repo", "goal", "checks", "assumptions", "plan", "size"],
 "properties": {"repo": {"type": "string"},` + draftFields + `}}}}}`

// draft is what Claude answers, in the shape of draftSchema. Repo is the
// repo of one run of a split draft.
type draft struct {
	Repo        string        `json:"repo,omitempty"`
	Goal        string        `json:"goal"`
	Checks      []store.Check `json:"checks"`
	Assumptions []string      `json:"assumptions"`
	Plan        []string      `json:"plan"`
	Size        string        `json:"size"`
}

// ShapeOptions says which run to shape. The fields are as for
// [StartOptions].
type ShapeOptions struct {
	PlotID   string
	Title    string
	Repo     string
	Base     string
	Link     string
	Ticket   string
	MaxTries int
	Model    string
	Effort   string
	// Brief is what Claude drafts the run from when it has no issue, such as
	// the prompt of a recurring run. Source is then the source of the run.
	Brief  string
	Source *store.RunSource
	// Split has Claude read every repo of the plot and draft one run for each
	// repo that the issue needs changes in. It takes no Repo.
	Split bool
}

// Shape records a run in Shaping, in the folder of its repo, and has Claude
// draft its goal, its Done when checks, its assumptions, and a plan (ticket
// 207). Claude reads the repo and the issue, and changes nothing. A draft
// that fails keeps the run, with the reason as its note. Nothing starts
// until you approve the run.
//
// With Split, Claude drafts one run for each repo that the issue needs
// changes in, and the runs share a group. Shape returns each run that it
// made, the first one first.
func Shape(ctx context.Context, s *store.Store, o ShapeOptions) ([]store.Run, error) {
	plot, err := s.GetPlot(o.PlotID)
	if err != nil {
		return nil, err
	}
	if plot.Archived {
		return nil, fmt.Errorf("%w: unarchive first with \"loam unarchive %s\"", store.ErrArchived, plot.ID)
	}
	title := strings.TrimSpace(o.Title)
	if title == "" {
		return nil, fmt.Errorf("a run needs a title: %w", store.ErrInvalid)
	}
	if o.Split && o.Repo != "" {
		return nil, fmt.Errorf("--split drafts a run for each repo that the issue needs, so it takes no --repo: %w", store.ErrInvalid)
	}
	if o.Model, o.Effort, err = withDefaults(s, plot.ID, o.Model, o.Effort); err != nil {
		return nil, err
	}
	source, err := ticketSource(o.Ticket, o.Link)
	if err != nil {
		return nil, err
	}
	// A split starts in the main repo, and Claude says which repos it needs.
	split := o.Split && len(plot.Repos) > 1
	link := o.Link
	if split {
		link = ""
	}
	repo, err := runRepo(plot, o.Repo, link)
	if err != nil {
		return nil, err
	}
	if source == nil {
		source = o.Source
	}
	if source == nil {
		l, err := worktree.ResolveLink(plot, repo.Path, o.Link)
		if err != nil {
			return nil, err
		}
		source = sourceOf(l)
	}
	r, err := s.AddRun(store.Run{
		PlotID: plot.ID, Folder: repo.Path, Title: title, State: store.RunShaping, MaxTries: o.MaxTries,
		Source: source, Note: draftingNote,
		Shape: &store.RunShape{Repo: repo.ID, Base: o.Base, Link: o.Link, Model: o.Model, Effort: o.Effort,
			Brief: strings.TrimSpace(o.Brief), Split: split},
	})
	if err != nil {
		return nil, err
	}
	return draftRun(ctx, s, r, "")
}

// Redraft has Claude draft a Shaping run again, with the change that you
// ask for, such as "Add a check for two screens". Claude sees its last
// draft. A run of a group is drafted alone, for its own repo. A split whose
// draft failed splits again, so Redraft can return more than one run.
func Redraft(ctx context.Context, s *store.Store, id, change string) ([]store.Run, error) {
	r, err := s.UpdateRun(id, func(r *store.Run) error {
		if r.State != store.RunShaping || r.Shape == nil {
			return fmt.Errorf("run %s is not Shaping, so it has no draft: %w", r.ID, store.ErrInvalid)
		}
		r.Note = draftingNote
		return nil
	})
	if err != nil {
		return nil, err
	}
	return draftRun(ctx, s, r, strings.TrimSpace(change))
}

// ApproveOptions are your edits to a draft, and how its session starts.
type ApproveOptions struct {
	// Goal replaces the drafted goal, when it is not nil.
	Goal *string
	// DoneWhen replaces the drafted checks, when it is not nil.
	DoneWhen []store.Check
	// Answers change assumptions, by number from 1. An assumption with no
	// answer stays as Claude made it.
	Answers      map[int]string
	ApproveSetup bool
	Loam         string
}

// Approve starts a Shaping run with your edits to its draft: it makes the
// worktree and starts the session, as [Start] does. When no slot is free,
// the run waits in Queued, as for [Start].
func Approve(ctx context.Context, s *store.Store, id string, o ApproveOptions) (*StartResult, error) {
	r, err := s.GetRun(id)
	if err != nil {
		return nil, err
	}
	if r.State != store.RunShaping || r.Shape == nil {
		return nil, fmt.Errorf("run %s is %s, and only a Shaping run is approved: %w", r.ID, r.State, store.ErrInvalid)
	}
	if r.Shape.DraftedAt == nil {
		return nil, fmt.Errorf("Claude has not drafted run %s yet. Draft it again with \"loam run redraft %s\": %w", r.ID, r.ID, store.ErrInvalid)
	}
	for n := range o.Answers {
		if n < 1 || n > len(r.Shape.Assumptions) {
			return nil, fmt.Errorf("the draft has no assumption %d: it has %d: %w", n, len(r.Shape.Assumptions), store.ErrInvalid)
		}
	}
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return nil, err
	}
	so := StartOptions{PlotID: r.PlotID, Title: r.Title, Repo: r.Shape.Repo, Base: r.Shape.Base, Link: r.Shape.Link,
		MaxTries: r.MaxTries, Model: r.Shape.Model, Effort: r.Shape.Effort, ApproveSetup: o.ApproveSetup, Loam: o.Loam}
	var ticket *store.RunSource
	if r.Source != nil && r.Source.Kind == intake.Map {
		ticket = r.Source
	}
	res := &StartResult{}
	wt, err := prepare(s, plot, so, r.Title, ticket, res)
	if err != nil {
		return nil, err
	}
	r, err = s.TakeSlot(r.ID, &store.RunQueue{Model: so.Model, Effort: so.Effort}, func(r *store.Run) error {
		if r.State != store.RunShaping {
			return fmt.Errorf("run %s is %s now: %w", r.ID, r.State, store.ErrInvalid)
		}
		r.WorktreeID, r.Folder, r.State, r.Note = wt.ID, wt.Path, store.RunStarting, ""
		if o.Goal != nil {
			r.Goal = strings.TrimSpace(*o.Goal)
		}
		if o.DoneWhen != nil {
			r.DoneWhen = o.DoneWhen
		}
		for n, answer := range o.Answers {
			r.Shape.Assumptions[n-1].Answer = strings.TrimSpace(answer)
		}
		if r.Source == nil {
			r.Source = sourceOf(wt.Link)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if r.State == store.RunQueued {
		res.Run = r
		return res, nil
	}
	return launch(ctx, s, r, so, res)
}

// draftRun has Claude draft the run in print mode, and records the draft, or
// the reason that there is none. A run that left Shaping meanwhile, such as
// one that you stopped, stays as it is. A run whose shape is a split gets a
// split draft (see [splitRun]).
func draftRun(ctx context.Context, s *store.Store, r store.Run, change string) ([]store.Run, error) {
	plot, err := s.GetPlot(r.PlotID)
	if err != nil {
		return nil, err
	}
	if r.Shape.Split {
		return splitRun(ctx, s, plot, r, change)
	}
	others, err := groupRepos(s, plot, r)
	if err != nil {
		return nil, err
	}
	d, failure := askForDraft(ctx, r, change, others, draftSteps(s, r.ID), usageRecorder(s))
	r, err = s.UpdateRun(r.ID, func(r *store.Run) error {
		if r.State != store.RunShaping || r.Shape == nil {
			return nil
		}
		if failure != "" {
			r.Note = "Claude could not draft the run: " + failure
			return nil
		}
		applyDraft(r, d)
		return nil
	})
	if err != nil || r.State != store.RunShaping {
		return []store.Run{r}, err
	}
	return []store.Run{r}, s.AddRunEvent(r.ID, "shape", shapeDetail(r, failure))
}

// splitRun has Claude read every repo of the plot and draft one run for each
// repo that the issue needs changes in. The run r becomes the run of the
// first repo of the draft, and each other repo gets a new Shaping run with
// the same title, source, and options. Two or more runs share a group: the
// ID of r. A draft with a repo that the plot does not have, or with a repo
// twice, fails as a whole, with the reason as the note of r.
func splitRun(ctx context.Context, s *store.Store, plot store.Plot, r store.Run, change string) ([]store.Run, error) {
	ds, failure := askForSplit(ctx, plot, r, change, draftSteps(s, r.ID), usageRecorder(s))
	var repos []store.Repo
	if failure == "" {
		repos, failure = splitRepos(plot, ds)
	}
	group := ""
	if len(ds) > 1 {
		group = r.ID
	}
	mainBase := r.Shape.Base
	base := func(repo store.Repo) string {
		// The base of a shape is a branch of the main repo.
		if m := plot.MainRepo(); m != nil && m.ID == repo.ID {
			return mainBase
		}
		return ""
	}
	r, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		if r.State != store.RunShaping || r.Shape == nil {
			return nil
		}
		if failure != "" {
			r.Note = "Claude could not draft the run: " + failure
			return nil
		}
		applyDraft(r, ds[0])
		r.Folder, r.GroupID = repos[0].Path, group
		r.Shape.Repo, r.Shape.Base, r.Shape.Split = repos[0].ID, base(repos[0]), false
		return nil
	})
	runs := []store.Run{r}
	if err != nil || r.State != store.RunShaping {
		return runs, err
	}
	if err := s.AddRunEvent(r.ID, "shape", shapeDetail(r, failure)); err != nil || failure != "" {
		return runs, err
	}
	for i, d := range ds[1:] {
		repo := repos[i+1]
		n := store.Run{PlotID: r.PlotID, Folder: repo.Path, Title: r.Title, State: store.RunShaping, MaxTries: r.MaxTries,
			Source: r.Source, GroupID: group,
			Shape: &store.RunShape{Repo: repo.ID, Base: base(repo), Link: r.Shape.Link, Model: r.Shape.Model,
				Effort: r.Shape.Effort, Brief: r.Shape.Brief}}
		applyDraft(&n, d)
		if n, err = s.AddRun(n); err != nil {
			return runs, err
		}
		runs = append(runs, n)
		if err := s.AddRunEvent(n.ID, "shape", shapeDetail(n, "")); err != nil {
			return runs, err
		}
	}
	return runs, nil
}

// splitRepos returns the repo of each run of a split draft, or why the draft
// cannot be used: a repo that the plot does not have, or a repo twice.
func splitRepos(plot store.Plot, ds []draft) ([]store.Repo, string) {
	if len(ds) == 0 {
		return nil, "the draft has no run"
	}
	var out []store.Repo
	for _, d := range ds {
		i := slices.IndexFunc(plot.Repos, func(r store.Repo) bool { return r.ID == d.Repo })
		if i < 0 {
			return nil, fmt.Sprintf("the draft has a run for %q, which is not a repo of the plot", d.Repo)
		}
		if slices.ContainsFunc(out, func(r store.Repo) bool { return r.ID == d.Repo }) {
			return nil, "the draft has more than one run for the repo " + d.Repo
		}
		out = append(out, plot.Repos[i])
	}
	return out, ""
}

// draftSteps records each step of a draft as a draft event of the run, up to
// draftStepsMax.
func draftSteps(s *store.Store, id string) func(string) {
	steps := 0
	return func(step string) {
		// A step that Loam cannot record is lost, and the draft goes on.
		if steps < draftStepsMax && s.AddRunEvent(id, "draft", step) == nil {
			steps++
		}
	}
}

// applyDraft puts the draft in the run.
func applyDraft(r *store.Run, d draft) {
	r.Goal, r.DoneWhen, r.Note = strings.TrimSpace(d.Goal), d.Checks, ""
	r.Shape.Assumptions = make([]store.Assumption, len(d.Assumptions))
	for i, a := range d.Assumptions {
		r.Shape.Assumptions[i] = store.Assumption{Text: a}
	}
	r.Shape.Plan, r.Shape.Size = d.Plan, strings.TrimSpace(d.Size)
	now := time.Now()
	r.Shape.DraftedAt = &now
}

// shapeDetail is the "shape" event of a run after a draft: what Claude
// drafted, or the note that says why there is no draft.
func shapeDetail(r store.Run, failure string) string {
	if failure != "" {
		return r.Note
	}
	return fmt.Sprintf("Claude drafted the goal and %d checks", len(r.DoneWhen))
}

// askForDraft has Claude draft one run in the folder of the run. others
// name the repos of the other runs of its group. step and usage are as for
// [askClaude].
func askForDraft(ctx context.Context, r store.Run, change string, others []string, step func(string), usage func(store.Usage)) (draft, string) {
	prompt := func(ctx context.Context) string { return shapePrompt(ctx, r, change, others) }
	out, failure := askClaude(ctx, r, nil, prompt, draftSchema, step, usage)
	if failure != "" {
		return draft{}, failure
	}
	var d draft
	if err := json.Unmarshal(out, &d); err != nil {
		return draft{}, "claude -p gave a draft that Loam cannot read: " + err.Error()
	}
	return cleanDraft(d), ""
}

// askForSplit has Claude draft one run for each repo of the plot that the
// issue needs changes in. Claude runs in the folder of r, the main repo, and
// reads the other repos too.
func askForSplit(ctx context.Context, plot store.Plot, r store.Run, change string, step func(string), usage func(store.Usage)) ([]draft, string) {
	var dirs []string
	for _, repo := range plot.Repos {
		if repo.Path != r.Folder {
			dirs = append(dirs, repo.Path)
		}
	}
	prompt := func(ctx context.Context) string { return splitPrompt(ctx, plot, r, change) }
	out, failure := askClaude(ctx, r, dirs, prompt, splitSchema, step, usage)
	if failure != "" {
		return nil, failure
	}
	var split struct {
		Runs []draft `json:"runs"`
	}
	if err := json.Unmarshal(out, &split); err != nil {
		return nil, "claude -p gave a draft that Loam cannot read: " + err.Error()
	}
	for i, d := range split.Runs {
		split.Runs[i] = cleanDraft(d)
	}
	return split.Runs, ""
}

// cleanDraft leaves out each check with no name or no command, because it
// cannot run.
func cleanDraft(d draft) draft {
	checks := []store.Check{}
	for _, c := range d.Checks {
		c.Name, c.Command = strings.TrimSpace(c.Name), strings.TrimSpace(c.Command)
		if c.Name != "" && c.Command != "" {
			checks = append(checks, c)
		}
	}
	d.Checks = checks
	d.Repo = strings.TrimSpace(d.Repo)
	return d
}

// askClaude runs claude -p in the folder of the run, with read-only tools and
// with --add-dir for each of dirs, and returns its structured output in the
// shape of schema, or why there is none. claude -p asks no trust question,
// so as for a run, each folder must be one that Claude Code trusts. It
// streams its output, and step gets each step that Claude takes, such as
// "Read window/frame.go", as it takes it. usage gets the usage that Claude
// Code reports.
func askClaude(ctx context.Context, r store.Run, dirs []string, prompt func(context.Context) string, schema string,
	step func(string), usage func(store.Usage)) (json.RawMessage, string) {
	for _, dir := range append([]string{r.Folder}, dirs...) {
		if !claudebin.Trusted(dir) {
			return nil, fmt.Sprintf("%v %s. Run claude in it once and choose Yes, then draft the run again", ErrUntrusted, dir)
		}
	}
	claude, err := claudebin.Find()
	if err != nil {
		return nil, err.Error()
	}
	ctx, cancel := context.WithTimeout(ctx, shapeTimeout)
	defer cancel()
	args := []string{"-p", prompt(ctx), "--output-format", "stream-json", "--verbose", "--json-schema", schema,
		"--no-session-persistence", "--tools", "Read,Grep,Glob"}
	for _, dir := range dirs {
		args = append(args, "--add-dir", dir)
	}
	if r.Shape.Model != "" {
		args = append(args, "--model", r.Shape.Model)
	}
	if r.Shape.Effort != "" {
		args = append(args, "--effort", r.Shape.Effort)
	}
	cmd := exec.CommandContext(ctx, claude, args...)
	cmd.Dir = r.Folder
	cmd.WaitDelay = time.Second
	var errOut bytes.Buffer
	cmd.Stderr = &errOut
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err.Error()
	}
	if err := cmd.Start(); err != nil {
		return nil, failureNote("claude -p failed", err, errOut.String())
	}
	res, readErr := readDraftStream(stdout, r.Folder, step, usage)
	if err := cmd.Wait(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		if ctx.Err() != nil {
			return nil, "claude -p did not answer in time"
		}
		return nil, failureNote("claude -p failed", err, errOut.String())
	}
	switch {
	case readErr != nil:
		return nil, "claude -p gave an answer that Loam cannot read: " + readErr.Error()
	case res == nil:
		return nil, "claude -p ended with no result"
	case res.IsError || len(res.StructuredOutput) == 0 || string(res.StructuredOutput) == "null":
		return nil, strings.TrimSpace(fmt.Sprintf("%s %s", res.Subtype, tail(res.Result, noteTail)))
	}
	return res.StructuredOutput, ""
}

// draftResult is the last message of claude -p: the draft, or why there is none.
type draftResult struct {
	IsError          bool            `json:"is_error"`
	Subtype          string          `json:"subtype"`
	Result           string          `json:"result"`
	StructuredOutput json.RawMessage `json:"structured_output"`
}

// readDraftStream reads the stream-json messages of claude -p. It gives each
// step of an assistant message to step, and the usage of each rate limit
// event to usage. It returns the result message.
func readDraftStream(out io.Reader, folder string, step func(string), usage func(store.Usage)) (*draftResult, error) {
	dec := json.NewDecoder(out)
	var res *draftResult
	for {
		var msg struct {
			Type    string `json:"type"`
			Message struct {
				Content []struct {
					Type  string         `json:"type"`
					Text  string         `json:"text"`
					Name  string         `json:"name"`
					Input map[string]any `json:"input"`
				} `json:"content"`
			} `json:"message"`
		}
		raw := json.RawMessage{}
		if err := dec.Decode(&raw); err == io.EOF {
			return res, nil
		} else if err != nil {
			return res, err
		}
		if err := json.Unmarshal(raw, &msg); err != nil {
			return res, err
		}
		switch msg.Type {
		case "result":
			res = &draftResult{}
			if err := json.Unmarshal(raw, res); err != nil {
				return nil, err
			}
		case "rate_limit_event":
			if u, ok := parseUsage(raw); ok {
				usage(u)
			}
		case "assistant":
			for _, c := range msg.Message.Content {
				if s := draftStep(c.Type, c.Text, c.Name, c.Input, folder); s != "" {
					step(s)
				}
			}
		}
	}
}

// draftStep says what one part of an assistant message did, for a person,
// or "" for a part that says nothing, such as thinking.
func draftStep(kind, text, tool string, input map[string]any, folder string) string {
	arg := func(key string) string { s, _ := input[key].(string); return s }
	switch {
	case kind == "text":
		line, _, _ := strings.Cut(strings.TrimSpace(text), "\n")
		return truncate(strings.TrimSpace(line), 200)
	case kind != "tool_use":
		return ""
	case tool == "Read":
		return "Read " + relativeTo(folder, arg("file_path"))
	case tool == "Grep":
		return "Searched for " + arg("pattern")
	case tool == "Glob":
		return "Looked for " + arg("pattern")
	case tool == "StructuredOutput":
		return "Wrote the draft"
	default:
		return "Used " + tool
	}
}

// relativeTo gives path from folder, or path as it is when it is not in the
// folder. A folder behind a symlink, such as /var on macOS, still matches.
func relativeTo(folder, path string) string {
	for _, dir := range []string{folder, resolved(folder)} {
		if rel, err := filepath.Rel(dir, path); err == nil && !strings.HasPrefix(rel, "..") {
			return rel
		}
	}
	return path
}

func resolved(path string) string {
	if r, err := filepath.EvalSymlinks(path); err == nil {
		return r
	}
	return path
}

// draftHow says what each field of a draft holds.
const draftHow = "- goal: what the run must do, in 2 to 4 plain sentences. Say what is true when the work is done.\n" +
	"- checks: 1 to 4 Done when checks. Each has a short name and a shell command that exits 0 in the repo when the work is done, " +
	"such as the tests of the area. Use the commands that the repo already has. The run can run the checks, but it cannot change them.\n" +
	"- assumptions: each choice that you made and the issue does not settle, in one sentence each. Give an empty list when there is none.\n" +
	"- plan: 2 to 6 short steps.\n" +
	"- size: one sentence about the size of the change, such as the lines and the areas that it changes.\n"

// shapePrompt asks Claude for a draft of the run, from its title and the
// text of its issue. With a change, it gives Claude the last draft and the
// change that you ask for. others name the repos of the other runs of its
// group.
func shapePrompt(ctx context.Context, r store.Run, change string, others []string) string {
	var b strings.Builder
	b.WriteString("You draft a run for Loam. A run is one goal that a Claude Code session works on alone, in a worktree of this repo, until its checks pass. " +
		"The session commits its work on its branch, and Loam then pushes the branch and opens the PR, so the plan needs no step for those. " +
		"Read the repo in this folder to learn how it is built and tested. Do not change any file.\n")
	if len(others) > 0 {
		fmt.Fprintf(&b, "\nThe issue needs changes in more than one repo, so it has one run in each. The other runs work in %s. "+
			"Draft this run alone, for the repo in this folder. The runs may land in any order, so this run must be correct alone, "+
			"or say in an assumption what it needs from another run.\n", joinAnd(others))
	}
	writeIssue(ctx, &b, r)
	b.WriteString("\nDraft the run:\n" + draftHow)
	if change != "" {
		last, _ := json.MarshalIndent(lastDraft(r), "", "  ")
		fmt.Fprintf(&b, "\nYour last draft:\n%s\n\nThe person asks for this change:\n%s\n\nDraft the run again with the change.\n", last, change)
	}
	return b.String()
}

// splitPrompt asks Claude for one draft for each repo of the plot that the
// issue of the run needs changes in.
func splitPrompt(ctx context.Context, plot store.Plot, r store.Run, change string) string {
	var b strings.Builder
	b.WriteString("You draft runs for Loam. A run is one goal that a Claude Code session works on alone, in a worktree of one repo, until its checks pass. " +
		"The session commits its work on its branch, and Loam then pushes the branch and opens the PR, so the plan needs no step for those.\n" +
		"\nThe issue can need changes in more than one repo of the plot. Draft one run for each repo that needs changes, and no run for a repo that needs none. " +
		"Each run works alone in a worktree of its repo, and its checks run there. The runs may land in any order, " +
		"so each run must be correct alone, or say in an assumption what it needs from another run.\n" +
		"\nRead the repos to learn how each one is built and tested. Do not change any file. The repos of the plot:\n")
	for _, repo := range plot.Repos {
		fmt.Fprintf(&b, "- %s: %s, at %s", repo.ID, repoLabel(repo), repo.Path)
		if repo.Path == r.Folder {
			b.WriteString(" (the main repo, in this folder)")
		}
		b.WriteString("\n")
	}
	writeIssue(ctx, &b, r)
	b.WriteString("\nDraft the runs. For each run:\n- repo: the ID of its repo, from the list. Give each repo at most once.\n" + draftHow)
	if change != "" {
		fmt.Fprintf(&b, "\nThe person asks for this change:\n%s\n", change)
	}
	return b.String()
}

// repoLabel names a repo for a person: its folder name, and its note.
func repoLabel(repo store.Repo) string {
	label := filepath.Base(repo.Path)
	if note := strings.TrimSpace(repo.Note); note != "" {
		label += " (" + note + ")"
	}
	return label
}

// writeIssue writes the title of the run, its brief, and the text of its
// issue.
func writeIssue(ctx context.Context, b *strings.Builder, r store.Run) {
	fmt.Fprintf(b, "\nTitle: %s\n", r.Title)
	if r.Shape != nil && r.Shape.Brief != "" {
		fmt.Fprintf(b, "\nThe brief:\n%s\n", r.Shape.Brief)
	}
	if r.Source != nil && r.Source.Kind != store.SourceRecurring {
		fmt.Fprintf(b, "Issue: %s (%s)\n", r.Source.Key, r.Source.URL)
		if text, err := issueText(ctx, *r.Source); err != nil {
			fmt.Fprintf(b, "Loam could not read the text of the issue: %v\n", err)
		} else if text != "" {
			fmt.Fprintf(b, "\nThe text of the issue:\n%s\n", text)
		}
	}
}

// lastDraft is the draft of the run as Claude gave it.
func lastDraft(r store.Run) draft {
	d := draft{Goal: r.Goal, Checks: r.DoneWhen, Plan: r.Shape.Plan, Size: r.Shape.Size, Assumptions: []string{}}
	for _, a := range r.Shape.Assumptions {
		d.Assumptions = append(d.Assumptions, a.Text)
	}
	return d
}

// issueText returns the text of the issue that a run starts from: the file
// of a map ticket, or the title and the body of a GitHub or Linear issue.
func issueText(ctx context.Context, src store.RunSource) (string, error) {
	var text string
	switch src.Kind {
	case intake.Map:
		b, err := os.ReadFile(src.URL)
		if err != nil {
			return "", err
		}
		text = string(b)
	case intake.GitHub:
		gh, err := github.NewClient()
		if err != nil {
			return "", err
		}
		if text, err = gh.IssueText(ctx, src.URL); err != nil {
			return "", err
		}
	case intake.Linear:
		c, err := linear.FromKeychain()
		if err != nil {
			return "", err
		}
		if text, err = c.IssueText(ctx, src.Key); err != nil {
			return "", err
		}
	}
	if len(text) > issueTextMax {
		text = strings.ToValidUTF8(text[:issueTextMax], "") + "\n[Loam cut the rest of the text]"
	}
	return strings.TrimSpace(text), nil
}

// truncate cuts text to at most n characters, with an ellipsis.
func truncate(text string, n int) string {
	runes := []rune(text)
	if len(runes) <= n {
		return text
	}
	return string(runes[:n-1]) + "…"
}
