package run

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
)

// checkTimeout limits one Done when check.
const checkTimeout = 10 * time.Minute

// gateBudget limits every check of one gate together. It ends 2 minutes
// before [session.RunHookTimeout], so the hook has time to record the result
// before Claude Code kills it.
const gateBudget = session.RunHookTimeout*time.Second - 2*time.Minute

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

// nestedSandbox is the error of a sandbox that cannot start inside another
// one, as SwiftPM's sandbox of its manifest inside the sandbox of a check.
const nestedSandbox = "sandbox_apply: Operation not permitted"

// nestedNote is the line that the failed log of a check gets when its output
// has nestedSandbox. Loam does not change the commands of a check.
const nestedNote = "Loam: a sandbox cannot start inside the sandbox of the checks. SwiftPM sandboxes its manifest, so pass --disable-sandbox to swift build, swift test, and swift package."

// gateResult is what the gate found.
type gateResult struct {
	results []checkResult
	failed  []checkResult
	// unsandboxed is why Loam could not sandbox the checks. Then no check
	// ran, and each one failed.
	unsandboxed error
}

// gate runs each Done when check of the run in its folder, then each rule
// of its plot, then the committed check, and records each result as a run
// event. Each check runs in the sandbox of the run. A rule that Loam cannot
// read is left out, with a log line.
func gate(ctx context.Context, s *store.Store, r store.Run, logf func(string, ...any)) gateResult {
	box := newCheckBox(s, r, logf)
	defer box.close(logf)
	g := gateResult{unsandboxed: box.err}
	for _, c := range r.DoneWhen {
		g.add(runCheck(ctx, r.Folder, box, c))
	}
	rules, err := s.ListRules(r.PlotID)
	if err != nil {
		logf("run %s: read the rules: %v", r.ID, err)
	}
	for _, rule := range rules {
		g.add(runCheck(ctx, r.Folder, box, rule.Check()))
	}
	g.add(committed(ctx, r.Folder, box))
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

// checkBox is the sandbox of the checks of one gate: sandbox-exec and the
// file of the profile.
type checkBox struct {
	exec, profile string
	// err is why Loam cannot sandbox the checks. Then each check fails and
	// does not run: a check runs code that the session wrote, and the gate
	// works outside the sandbox of the session.
	err error
}

// profilePrefix and profileSuffix name the profile files in the Loam home
// folder: gate-<pid>-<random>.sb, with the process ID of the gate.
const profilePrefix, profileSuffix = "gate-", ".sb"

// sandboxProbeTimeout limits the start of the sandbox with no check.
const sandboxProbeTimeout = 10 * time.Second

// newCheckBox writes the rules of the run as a Seatbelt profile, to a file in
// the Loam home folder that only the user can read. No check can write that
// folder, so no check can change the profile of the next one. It then starts
// the sandbox once with no check, so that a sandbox that cannot start, as in
// a process that is already in a sandbox, fails the gate and not each check.
func newCheckBox(s *store.Store, r store.Run, logf func(string, ...any)) checkBox {
	if err := sandbox.Available(); err != nil {
		return checkBox{err: err}
	}
	rules, err := session.RunRules(s, r)
	if err != nil {
		return checkBox{err: err}
	}
	temps := sandbox.Temps()
	text, err := rules.Profile(temps...)
	if err != nil {
		return checkBox{err: err}
	}
	if rules.Writable(s.Home(), temps...) {
		return checkBox{err: fmt.Errorf("the checks could write the Loam home folder %s, which holds their sandbox profile", s.Home())}
	}
	removeOldProfiles(s.Home(), logf)
	f, err := os.CreateTemp(s.Home(), fmt.Sprintf("%s%d-*%s", profilePrefix, os.Getpid(), profileSuffix))
	if err != nil {
		return checkBox{err: fmt.Errorf("write the sandbox profile: %w", err)}
	}
	box := checkBox{exec: sandbox.Exec(), profile: f.Name()}
	_, err = f.WriteString(text)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		box.close(logf)
		return checkBox{err: fmt.Errorf("write the sandbox profile: %w", err)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), sandboxProbeTimeout)
	defer cancel()
	if out, err := exec.CommandContext(ctx, box.exec, "-f", box.profile, "/usr/bin/true").CombinedOutput(); err != nil {
		box.close(logf)
		return checkBox{err: fmt.Errorf("sandbox-exec cannot start the sandbox: %v %s", err, strings.TrimSpace(string(out)))}
	}
	return box
}

// removeOldProfiles removes the profile files of the gates that ended with
// no clean up, as when Claude Code killed the hook: the files whose process
// has ended. A reused process ID only keeps a file.
func removeOldProfiles(home string, logf func(string, ...any)) {
	entries, err := os.ReadDir(home)
	if err != nil {
		logf("read the Loam home folder for old sandbox profiles: %v", err)
		return
	}
	for _, e := range entries {
		name := e.Name()
		rest, ok := strings.CutPrefix(name, profilePrefix)
		if !ok || !strings.HasSuffix(name, profileSuffix) {
			continue
		}
		digits, _, _ := strings.Cut(rest, "-")
		pid, err := strconv.Atoi(digits)
		if err != nil || pid <= 0 || alive(pid) {
			continue
		}
		if err := os.Remove(filepath.Join(home, name)); err != nil {
			logf("remove the old sandbox profile %s: %v", name, err)
		}
	}
}

// alive reports whether a process with the ID runs. A process of another
// user counts as alive.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// close removes the file of the profile.
func (b checkBox) close(logf func(string, ...any)) {
	if b.profile == "" {
		return
	}
	if err := os.Remove(b.profile); err != nil {
		logf("remove the sandbox profile %s: %v", b.profile, err)
	}
}

// runCheck runs one check as sh -c in dir, in the sandbox of box. When ctx
// has ended, as at the end of the gate budget, or when box has no sandbox,
// the check fails and does not run.
func runCheck(ctx context.Context, dir string, box checkBox, c store.Check) checkResult {
	if ctx.Err() != nil {
		return checkResult{check: c, exit: -1, output: "Loam did not run the check: the checks ran out of time."}
	}
	if box.err != nil {
		return checkResult{check: c, exit: -1, output: "Loam did not run the check, because it could not sandbox it: " + box.err.Error()}
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, box.exec, "-f", box.profile, "sh", "-c", c.Command)
	cmd.Dir = dir
	cmd.WaitDelay = time.Second
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	start := time.Now()
	err := cmd.Run()
	res := checkResult{check: c, passed: err == nil, output: out.String(), duration: time.Since(start)}
	var exit *exec.ExitError
	switch {
	case parent.Err() != nil:
		res.passed, res.exit = false, -1
		res.output += "\nThe checks ran out of time before this check ended."
	case ctx.Err() != nil:
		res.passed, res.exit = false, -1
		res.output += fmt.Sprintf("\nThe check did not end in %s.", checkTimeout)
	case errors.As(err, &exit):
		res.exit = exit.ExitCode()
	case err != nil:
		res.exit = -1
		res.output += "\n" + err.Error()
	}
	if !res.passed && strings.Contains(res.output, nestedSandbox) {
		res.output = strings.TrimRight(res.output, "\n") + "\n" + nestedNote
	}
	return res
}

// committed checks that git status in dir shows no work.
func committed(ctx context.Context, dir string, box checkBox) checkResult {
	c := store.Check{Name: CommittedCheck, Command: "git status --porcelain"}
	res := runCheck(ctx, dir, box, c)
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
