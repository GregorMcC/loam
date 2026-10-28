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

// prTextTimeout limits the claude -p call that fills in a PR template.
var prTextTimeout = 3 * time.Minute

// prTemplateMax is how much of a PR template the prompt keeps.
const prTemplateMax = 20000

// prContextMax is how much of the commit messages and of the diff summary the
// prompt keeps.
const prContextMax = 8000

// prTextSchema is the JSON Schema of the PR text, for claude -p --json-schema.
const prTextSchema = `{"type": "object", "additionalProperties": false, "required": ["title", "body"],
 "properties": {"title": {"type": "string"}, "body": {"type": "string"}}}`

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

// prText returns the title and the body of the PR of the run. With a PR
// template in the worktree, Claude fills it in. Without one, or when Claude
// cannot, the title is the title of the run and the body is [prBody]; then,
// only with a template, a "ship" event says why.
func (sh *shipper) prText(ctx context.Context, w store.Worktree, repo github.Repo, others []string) (title, body string) {
	r := sh.r
	title, body = r.Title, prBody(r, repo, others)
	template := prTemplate(r.Folder)
	if template == "" {
		return title, body
	}
	filled, why := askForPRText(ctx, r, w, template)
	if why != "" {
		if err := sh.s.AddRunEvent(r.ID, "ship", "Loam used no PR template: "+why); err != nil {
			sh.warnings = append(sh.warnings, err.Error())
		}
		return title, body
	}
	return cmp.Or(filled.Title, title), strings.TrimSpace(filled.Body) + "\n" + prFooter(r, repo, others)
}

// prTextAnswer is the PR text that Claude writes.
type prTextAnswer struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// askForPRText has Claude fill in the PR template from the work of the run:
// claude -p in the worktree, with read-only tools. It returns why there is no
// text when Claude cannot give it.
func askForPRText(ctx context.Context, r store.Run, w store.Worktree, template string) (prTextAnswer, string) {
	if !claudebin.Trusted(r.Folder) {
		return prTextAnswer{}, fmt.Sprintf("Claude Code does not trust %s. Run claude in it once and choose Yes", r.Folder)
	}
	claude, err := claudebin.Find()
	if err != nil {
		return prTextAnswer{}, err.Error()
	}
	ctx, cancel := context.WithTimeout(ctx, prTextTimeout)
	defer cancel()
	args := []string{"-p", prTextPrompt(ctx, r, w, template), "--output-format", "json", "--json-schema", prTextSchema,
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
			return prTextAnswer{}, "claude -p did not answer in time"
		}
		return prTextAnswer{}, failureNote("claude -p failed", err, errOut.String())
	}
	var res draftResult
	if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &res); err != nil {
		return prTextAnswer{}, "claude -p gave an answer that Loam cannot read: " + err.Error()
	}
	if res.IsError || len(res.StructuredOutput) == 0 || string(res.StructuredOutput) == "null" {
		return prTextAnswer{}, strings.TrimSpace(fmt.Sprintf("claude -p gave no text. %s %s", res.Subtype, tail(res.Result, noteTail)))
	}
	var a prTextAnswer
	if err := json.Unmarshal(res.StructuredOutput, &a); err != nil {
		return prTextAnswer{}, "claude -p gave a text that Loam cannot read: " + err.Error()
	}
	a.Title = strings.TrimSpace(a.Title)
	if strings.TrimSpace(a.Body) == "" {
		return prTextAnswer{}, "claude -p gave an empty body"
	}
	return a, ""
}

// prTextPrompt is the prompt that asks for the PR text: the template, the
// goal, the checks, the commits, and the summary of the diff.
func prTextPrompt(ctx context.Context, r store.Run, w store.Worktree, template string) string {
	var b strings.Builder
	b.WriteString("Write the title and the body of the pull request for the work in this folder. " +
		"Answer in the JSON shape that the schema gives: a title and a body.\n\n" +
		"Fill in each section of the template below from the work. " +
		"Follow the comments in the template: delete a section when the template says to delete it for a change like this one. " +
		"Tick a checkbox only when one of the checks below proves it. Leave every other checkbox unticked, for the person to tick. " +
		"Write plainly. Use no em dashes. Do not name a local path. " +
		"You can read the files of the repo with your tools, and you can change nothing.\n\n")
	b.WriteString("## Template\n\n" + truncate(template, prTemplateMax) + "\n\n")
	fmt.Fprintf(&b, "## Goal\n\n%s\n\n## Checks, all passed\n\n", strings.TrimSpace(cmp.Or(r.Goal, r.Title)))
	for _, c := range r.DoneWhen {
		fmt.Fprintf(&b, "- %s: `%s` (passed)\n", c.Name, c.Command)
	}
	fmt.Fprintf(&b, "- %s (passed)\n", CommittedCheck)
	base, err := gitOut(ctx, r.Folder, "merge-base", w.Base, "HEAD")
	if err == nil && base != "" {
		if log, err := gitOut(ctx, r.Folder, "log", "--reverse", "--format=%h %s%n%b", base+"..HEAD"); err == nil && log != "" {
			b.WriteString("\n## Commits\n\n" + truncate(log, prContextMax) + "\n")
		}
		if stat, err := gitOut(ctx, r.Folder, "diff", "--stat", base, "HEAD"); err == nil && stat != "" {
			b.WriteString("\n## Changed files\n\n```\n" + truncate(stat, prContextMax) + "\n```\n")
		}
	}
	return b.String()
}
