package run

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// checkTimeout limits one Done when check. The Stop hook of a run has
// [session.RunHookTimeout] for every check together.
const checkTimeout = 10 * time.Minute

// reasonTail is how many lines of a failed check's output go back to the
// session.
const reasonTail = 60

// CommittedCheck is the name of the check that the gate adds to every run:
// the worktree has no uncommitted work, so the branch holds all of it.
const CommittedCheck = "Work committed"

// checkResult is the result of one check.
type checkResult struct {
	check    store.Check
	passed   bool
	exit     int
	output   string
	duration time.Duration
}

// gateResult is what the gate found.
type gateResult struct {
	results []checkResult
	failed  []checkResult
}

// gate runs each Done when check of the run in its folder, then the
// committed check, and records each result as a run event.
func gate(ctx context.Context, s *store.Store, r store.Run, logf func(string, ...any)) gateResult {
	var g gateResult
	for _, c := range r.DoneWhen {
		g.add(runCheck(ctx, r.Folder, c))
	}
	g.add(committed(ctx, r.Folder))
	for _, res := range g.results {
		detail := fmt.Sprintf("%s passed (%s)", res.check.Name, res.duration.Round(time.Second))
		if !res.passed {
			detail = fmt.Sprintf("%s failed (exit %d, %s)", res.check.Name, res.exit, res.duration.Round(time.Second))
		}
		if err := s.AddRunEvent(r.ID, "check", detail); err != nil {
			logf("run %s: record check: %v", r.ID, err)
		}
	}
	return g
}

func (g *gateResult) add(res checkResult) {
	g.results = append(g.results, res)
	if !res.passed {
		g.failed = append(g.failed, res)
	}
}

// runCheck runs one check with sh -c in dir.
func runCheck(ctx context.Context, dir string, c store.Check) checkResult {
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", "-c", c.Command)
	cmd.Dir = dir
	cmd.WaitDelay = time.Second
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	start := time.Now()
	err := cmd.Run()
	res := checkResult{check: c, passed: err == nil, output: out.String(), duration: time.Since(start)}
	var exit *exec.ExitError
	switch {
	case ctx.Err() != nil:
		res.passed, res.exit = false, -1
		res.output += fmt.Sprintf("\nThe check did not end in %s.", checkTimeout)
	case errors.As(err, &exit):
		res.exit = exit.ExitCode()
	case err != nil:
		res.exit = -1
		res.output += "\n" + err.Error()
	}
	return res
}

// committed checks that git status in dir shows no work.
func committed(ctx context.Context, dir string) checkResult {
	c := store.Check{Name: CommittedCheck, Command: "git status --porcelain"}
	res := runCheck(ctx, dir, c)
	if res.passed && strings.TrimSpace(res.output) != "" {
		res.passed, res.exit = false, 1
		res.output = "These files are not committed. Commit them, or add them to .gitignore:\n" + res.output
	}
	return res
}

// reason is the text that a blocked stop sends to the session.
func reason(r store.Run, g gateResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Loam gate: %d of %d checks failed (try %d of %d). Fix the failures, then end your turn. Loam runs the checks again.\n",
		len(g.failed), len(g.results), r.Tries, r.MaxTries)
	for _, f := range g.failed {
		fmt.Fprintf(&b, "\n## %s: `%s` (exit %d)\n%s\n", f.check.Name, f.check.Command, f.exit, tail(f.output, reasonTail))
	}
	return b.String()
}

// failedNames joins the names of the failed checks.
func failedNames(g gateResult) string {
	names := make([]string, len(g.failed))
	for i, f := range g.failed {
		names[i] = f.check.Name
	}
	return strings.Join(names, ", ")
}

// tail returns the last n lines of text.
func tail(text string, n int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(lines) > n {
		lines = append([]string{fmt.Sprintf("(%d earlier lines cut)", len(lines)-n)}, lines[len(lines)-n:]...)
	}
	return strings.Join(lines, "\n")
}
