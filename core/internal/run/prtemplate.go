package run

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

// prTextTimeout limits the claude -p call that writes the ship notes and
// fills in a PR template.
var prTextTimeout = 3 * time.Minute

// prTemplateMax is how much of a PR template the prompt keeps.
const prTemplateMax = 20000

// prContextMax is how much of the commit messages and of the diff summary the
// prompt keeps.
const prContextMax = 8000

// prTemplate returns the text of the PR template of the repo in dir, found as
// GitHub finds it: a file named pull_request_template (.md or .txt, any case)
// in .github, in the root, or in docs, else the first file of a folder named
// PULL_REQUEST_TEMPLATE in one of them. It returns "" when there is none.
func prTemplate(dir string) string {
	places := []string{filepath.Join(dir, ".github"), dir, filepath.Join(dir, "docs")}
	for _, place := range places {
		entries, err := os.ReadDir(place)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.Type().IsRegular() && isTemplateFile(e.Name(), "pull_request_template") {
				if text := readTemplate(filepath.Join(place, e.Name())); text != "" {
					return text
				}
			}
		}
	}
	for _, place := range places {
		entries, err := os.ReadDir(place)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() || !strings.EqualFold(e.Name(), "pull_request_template") {
				continue
			}
			files, err := os.ReadDir(filepath.Join(place, e.Name()))
			if err != nil {
				continue
			}
			for _, f := range files { // sorted by name
				if f.Type().IsRegular() && isTemplateFile(f.Name(), "") {
					if text := readTemplate(filepath.Join(place, e.Name(), f.Name())); text != "" {
						return text
					}
				}
			}
		}
	}
	return ""
}

// isTemplateFile reports whether name is a template file: a .md or .txt file,
// and with a stem, one with that stem in any case.
func isTemplateFile(name, stem string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	if ext != ".md" && ext != ".txt" {
		return false
	}
	return stem == "" || strings.EqualFold(strings.TrimSuffix(name, filepath.Ext(name)), stem)
}

// readTemplate returns the text of a template file, or "" when it is empty or
// cannot be read.
func readTemplate(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// prText returns the title and the body of the PR of the run, and its ship
// notes. Claude writes the notes for every PR that Loam opens. With a PR
// template in the worktree, Claude also fills it in. Without one, or when
// Claude cannot, the title is the title of the run and the body is
// [prBody]. When Claude gives no notes, or with a template no body, a "ship"
// event says why. where is the Where it stands of the plot now.
func (sh *shipper) prText(ctx context.Context, w store.Worktree, repo github.Repo, others []string, where string) (title, body string, notes *store.RunNotes) {
	r := sh.r
	title, body = r.Title, prBody(r, repo, others)
	template := prTemplate(r.Folder)
	changed := changedFiles(ctx, r.Folder, w.Base)
	a, why := askForShipText(ctx, r, w, shipAsk{template: template, where: where, changed: changed})
	switch {
	case why != "" && template != "":
		sh.shipEvent("Loam used no PR template and wrote no ship notes: " + why)
		return title, body, nil
	case why != "":
		sh.shipEvent("Loam wrote no ship notes: " + why)
		return title, body, nil
	}
	if template != "" {
		if strings.TrimSpace(a.Body) == "" {
			sh.shipEvent("Loam used no PR template: claude -p gave an empty body")
		} else {
			title, body = cmp.Or(strings.TrimSpace(a.Title), title), strings.TrimSpace(a.Body)+"\n"+prFooter(r, repo, others)
		}
	}
	if strings.TrimSpace(a.Walkthrough) == "" {
		sh.shipEvent("Loam wrote no ship notes: claude -p gave no walkthrough")
		return title, body, nil
	}
	return title, body, shipNotes(r, a, changed)
}

// shipEvent records a "ship" event. A failure to record it is a warning.
func (sh *shipper) shipEvent(detail string) {
	if err := sh.s.AddRunEvent(sh.r.ID, "ship", detail); err != nil {
		sh.warnings = append(sh.warnings, err.Error())
	}
}

// shipAsk is what the prompt for the ship text holds besides the run: the PR
// template or "", the Where it stands of the plot, and the changed files, or
// nil when git cannot say.
type shipAsk struct {
	template string
	where    string
	changed  []string
}

// shipAnswer is the ship text that Claude writes. Title and Body are there
// only for a PR template.
type shipAnswer struct {
	Title         string           `json:"title"`
	Body          string           `json:"body"`
	Walkthrough   string           `json:"walkthrough"`
	Files         []store.NoteFile `json:"files"`
	Risk          store.NoteRisk   `json:"risk"`
	WhereItStands string           `json:"where_it_stands"`
}

// shipTextSchema is the JSON Schema of the ship text, for claude -p
// --json-schema. With a template, it also asks for the title and the body.
func shipTextSchema(template bool) string {
	str := map[string]any{"type": "string"}
	object := func(required []string, props map[string]any) map[string]any {
		return map[string]any{"type": "object", "additionalProperties": false, "required": required, "properties": props}
	}
	props := map[string]any{
		"walkthrough": str,
		"files": map[string]any{"type": "array",
			"items": object([]string{"path", "role"}, map[string]any{"path": str, "role": str})},
		"risk": object([]string{"level", "reasons"}, map[string]any{
			"level":   map[string]any{"type": "string", "enum": []string{store.RiskLow, store.RiskMedium, store.RiskHigh}},
			"reasons": map[string]any{"type": "array", "items": str},
		}),
		"where_it_stands": str,
	}
	required := []string{"walkthrough", "files", "risk", "where_it_stands"}
	if template {
		props["title"], props["body"] = str, str
		required = append([]string{"title", "body"}, required...)
	}
	b, err := json.Marshal(object(required, props))
	if err != nil { // maps of strings always encode
		panic(err)
	}
	return string(b)
}

// askForShipText has Claude write the ship notes, and fill in the PR template
// when there is one, from the work of the run: claude -p in the worktree, with
// read-only tools. It returns why there is no text when Claude cannot give it.
func askForShipText(ctx context.Context, r store.Run, w store.Worktree, ask shipAsk) (shipAnswer, string) {
	if !claudebin.Trusted(r.Folder) {
		return shipAnswer{}, fmt.Sprintf("Claude Code does not trust %s. Run claude in it once and choose Yes", r.Folder)
	}
	claude, err := claudebin.Find()
	if err != nil {
		return shipAnswer{}, err.Error()
	}
	ctx, cancel := context.WithTimeout(ctx, prTextTimeout)
	defer cancel()
	args := []string{"-p", shipTextPrompt(ctx, r, w, ask), "--output-format", "json", "--json-schema", shipTextSchema(ask.template != ""),
		"--no-session-persistence", "--tools", "Read,Grep,Glob"}
	if r.Shape != nil {
		if r.Shape.Model != "" {
			args = append(args, "--model", r.Shape.Model)
		}
		if r.Shape.Effort != "" {
			args = append(args, "--effort", r.Shape.Effort)
		}
	}
	cmd := exec.CommandContext(ctx, claude, args...)
	cmd.Dir = r.Folder
	cmd.WaitDelay = time.Second
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		if ctx.Err() != nil {
			return shipAnswer{}, "claude -p did not answer in time"
		}
		return shipAnswer{}, failureNote("claude -p failed", err, errOut.String())
	}
	var res draftResult
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &res); err != nil {
		return shipAnswer{}, "claude -p gave an answer that Loam cannot read: " + err.Error()
	}
	if res.IsError || len(res.StructuredOutput) == 0 || string(res.StructuredOutput) == "null" {
		return shipAnswer{}, strings.TrimSpace(fmt.Sprintf("claude -p gave no text. %s %s", res.Subtype, tail(res.Result, noteTail)))
	}
	var a shipAnswer
	if err := json.Unmarshal(res.StructuredOutput, &a); err != nil {
		return shipAnswer{}, "claude -p gave a text that Loam cannot read: " + err.Error()
	}
	return a, ""
}

// shipTextPrompt is the prompt that asks for the ship text: what each part
// of the notes is, the template, the Where it stands of the plot, the goal,
// the checks, the plan, the commits, and the changed files.
func shipTextPrompt(ctx context.Context, r store.Run, w store.Worktree, ask shipAsk) string {
	var b strings.Builder
	if ask.template != "" {
		b.WriteString("Write the title and the body of the pull request for the work in this folder, and the notes that a reviewer reads before the merge. " +
			"Answer in the JSON shape that the schema gives.\n\n" +
			"Fill in each section of the template below from the work. " +
			"Follow the comments in the template: delete a section when the template says to delete it for a change like this one. " +
			"Tick a checkbox only when one of the checks below proves it. Leave every other checkbox unticked, for the person to tick.\n\n")
	} else {
		b.WriteString("Write the notes that a reviewer reads before the merge of the work in this folder. " +
			"Answer in the JSON shape that the schema gives.\n\n")
	}
	b.WriteString("The notes:\n\n" +
		"- walkthrough: 2 to 4 plain sentences that say what changed and why.\n" +
		"- files: each changed file below, once, in the order that a reviewer should read them. " +
		"Give each one a role of 1 to 4 words, such as \"The rule\", \"Tests\", or \"What you see\".\n" +
		"- risk: the level (low, medium, or high), and short sentences that say why, such as what could break and what the checks do not cover.\n" +
		"- where_it_stands: a new text for Where it stands of the plot. Start from the text below, keep what is still true, " +
		"and move it on by this change. Keep it about as long as it is now.\n\n" +
		"Write plainly. Use no em dashes. Do not name a local path. " +
		"You can read the files of the repo with your tools, and you can change nothing.\n\n")
	if ask.template != "" {
		b.WriteString("## Template\n\n" + truncate(ask.template, prTemplateMax) + "\n\n")
	}
	fmt.Fprintf(&b, "## Where it stands now\n\n%s\n\n", cmp.Or(strings.TrimSpace(ask.where), "(empty)"))
	fmt.Fprintf(&b, "## Goal\n\n%s\n\n## Checks, all passed\n\n", strings.TrimSpace(cmp.Or(r.Goal, r.Title)))
	for _, c := range r.DoneWhen {
		fmt.Fprintf(&b, "- %s: `%s` (passed)\n", c.Name, c.Command)
	}
	fmt.Fprintf(&b, "- %s (passed)\n", CommittedCheck)
	if r.Shape != nil && len(r.Shape.Plan) > 0 {
		b.WriteString("\n## Plan\n\n")
		for i, step := range r.Shape.Plan {
			fmt.Fprintf(&b, "%d. %s\n", i+1, step)
		}
	}
	base, err := gitOut(ctx, r.Folder, "merge-base", w.Base, "HEAD")
	if err == nil && base != "" {
		if log, err := gitOut(ctx, r.Folder, "log", "--reverse", "--format=%h %s%n%b", base+"..HEAD"); err == nil && log != "" {
			b.WriteString("\n## Commits\n\n" + truncate(log, prContextMax) + "\n")
		}
		if stat, err := gitOut(ctx, r.Folder, "diff", "--stat", base, "HEAD"); err == nil && stat != "" {
			b.WriteString("\n## Size of the change\n\n```\n" + truncate(stat, prContextMax) + "\n```\n")
		}
	}
	if len(ask.changed) > 0 {
		b.WriteString("\n## Changed files\n\n" + truncate("- "+strings.Join(ask.changed, "\n- "), prContextMax) + "\n")
	}
	return b.String()
}

// changedFiles returns the paths that the branch of the run in dir changed
// since it left base, or nil when git cannot say.
func changedFiles(ctx context.Context, dir, base string) []string {
	if base == "" {
		return nil
	}
	from, err := gitOut(ctx, dir, "merge-base", base, "HEAD")
	if err != nil || from == "" {
		return nil
	}
	out, err := gitOut(ctx, dir, "-c", "core.quotePath=off", "diff", "--name-only", "--no-ext-diff", "-M", from, "HEAD")
	if err != nil {
		return nil
	}
	if out == "" {
		return []string{}
	}
	return strings.Split(out, "\n")
}
