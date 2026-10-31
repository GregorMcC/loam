package run

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/sandbox"
	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
)

// checkTimeout limits one Done when check. A var, for tests.
var checkTimeout = 10 * time.Minute

// gateBudget limits one gate: the wait for the gate lock and every check
// together. It ends 2 minutes before [session.RunHookTimeout], so the hook
// has time to record the result before Claude Code kills it. A var, for
// tests.
var gateBudget = session.RunHookTimeout*time.Second - 2*time.Minute

// gateLockFile is the lock file in the Loam home that a gate holds while it
// runs its checks, so the gates of the runs on one Mac take turns. Checks
// that run at once slow each other down past [checkTimeout].
const gateLockFile = "gate.lock"

// gateLockPoll is how often a gate that waits tries the gate lock again. A
// var, for tests.
var gateLockPoll = 5 * time.Second

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
	// timeout says how the check ran out of time, such as "did not end in
	// 10m", or is "" when it did not. A check that ran out of time failed.
	timeout string
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
	// waited is how long the gate waited for the gate lock.
	waited time.Duration
	// waitedOut is true when the wait for the gate lock left no time for the
	// checks. Then no check ran, and results is empty.
	waitedOut bool
}

// gate takes the gate lock (see [takeGateLock]), then runs each Done when
// check of the run in its folder, then each rule of its plot, then the
// committed check, and records each result as a run event. Each check runs
// in the sandbox of the run. A rule that Loam cannot read is left out, with a
// log line.
func gate(ctx context.Context, s *store.Store, r store.Run, logf func(string, ...any)) gateResult {
	unlock, waited, ok := takeGateLock(ctx, s, r, logf)
	if !ok {
		return gateResult{waited: waited, waitedOut: true}
	}
	defer unlock()
	box := newCheckBox(s, r)
	defer box.close()
	g := gateResult{unsandboxed: box.err, waited: waited}
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
		switch {
		case res.timeout != "":
			detail = res.check.Name + " " + res.timeout
		case !res.passed:
			detail = fmt.Sprintf("%s failed (exit %d, %s)", res.check.Name, res.exit, res.duration.Round(time.Second))
		}
		if err := s.AddRunEventData(r.ID, "check", detail, store.RunEventData{Check: res.stored()}); err != nil {
			logf("run %s: record check: %v", r.ID, err)
		}
	}
	return g
}

// stored is the result as a "check" event keeps it: the output of a failed
// check, cut to [store.CheckOutputMax], and no output of a check that passed.
func (res checkResult) stored() *store.RunCheckResult {
	c := &store.RunCheckResult{Name: res.check.Name, Command: res.check.Command, Passed: res.passed, Exit: res.exit}
	if !res.passed {
		c.Output, c.OutputCut = store.CutOutput(res.output)
	}
	return c
}

// LastGate returns the results of the checks of the last gate of a run, in
// the order that they ran: the last block of "check" events in events. A
// check event from before Loam stored its result is left out.
func LastGate(events []store.RunEvent) []store.RunCheckResult {
	var out []store.RunCheckResult
	seen := false
	for _, e := range slices.Backward(events) {
		if e.Kind != "check" {
			if seen {
				break
			}
			continue
		}
		seen = true
		if e.Check != nil {
			out = append(out, *e.Check)
		}
	}
	slices.Reverse(out)
	return out
}

func (g *gateResult) add(res checkResult) {
	g.results = append(g.results, res)
	if !res.passed {
		g.failed = append(g.failed, res)
	}
}

// outOfTime says why the gate ran out of time, when it did: the wait for the
// gate lock left no time for the checks, or a check failed only because it
// ran out of time. The session cannot fix that, so such a gate counts no
// try. A gate with any other failure did not run out of time, as the session
// can fix that failure.
func (g gateResult) outOfTime() (string, bool) {
	if g.waitedOut {
		return "The gate waited " + shortDuration(g.waited) + " for the gate of another run, which left no time for the checks", true
	}
	if len(g.failed) == 0 {
		return "", false
	}
	for _, f := range g.failed {
		if f.timeout == "" {
			return "", false
		}
	}
	// The first one ran out of time. The checks after it did not run.
	f := g.failed[0]
	return f.check.Name + " " + f.timeout, true
}

// takeGateLock takes the gate lock of the Loam home, so that one gate at a
// time runs its checks. This lock is for every run of the home. A gate that
// finds the lock taken records a gate event and waits. The wait does not
// count toward [checkTimeout], but it counts toward the deadline of ctx, the
// gate budget. So the gate waits only while the budget keeps checkTimeout for
// the checks, and reports false when that time is up. A lock file that Loam
// cannot open or lock does not hold the gate back: it logs the error and
// runs the checks.
func takeGateLock(ctx context.Context, s *store.Store, r store.Run, logf func(string, ...any)) (unlock func(), waited time.Duration, ok bool) {
	path := filepath.Join(s.Home(), gateLockFile)
	start := time.Now()
	deadline, limited := ctx.Deadline()
	deadline = deadline.Add(-checkTimeout)
	event := func(detail string) {
		if err := s.AddRunEvent(r.ID, "gate", detail); err != nil {
			logf("run %s: record the gate wait: %v", r.ID, err)
		}
	}
	waiting := false
	for {
		unlock, ok, err := lockFile(path)
		switch {
		case err != nil:
			logf("run %s: take the gate lock: %v", r.ID, err)
			return func() {}, time.Since(start), true
		case ok:
			if waiting {
				event("Waited " + shortDuration(time.Since(start)) + " for the gate of another run")
			}
			return unlock, time.Since(start), true
		case !waiting:
			event("Waits for the gate of another run to end its checks")
			waiting = true
		}
		wait := gateLockPoll
		if limited {
			left := time.Until(deadline)
			if left <= 0 {
				event("Waited " + shortDuration(time.Since(start)) + " for the gate of another run, which left no time for the checks")
				return nil, time.Since(start), false
			}
			wait = min(wait, left)
		}
		select {
		case <-ctx.Done():
			return nil, time.Since(start), false
		case <-time.After(wait):
		}
	}
}

// shortDuration gives d in whole seconds without the zero units at the end,
// such as "10m" or "3m12s". A duration under a second, as in tests, stays as
// it is.
func shortDuration(d time.Duration) string {
	if d < time.Second {
		return d.String()
	}
	out := d.Round(time.Second).String()
	if strings.HasSuffix(out, "m0s") {
		out = strings.TrimSuffix(out, "0s")
	}
	if strings.HasSuffix(out, "h0m") {
		out = strings.TrimSuffix(out, "0m")
	}
	return out
}

// checkBox is the sandbox of the checks of one gate: sandbox-exec and the
// profile.
type checkBox struct {
	exec, profile string
	// dir is the folder of the gate, which Loam removes after the gate. The
	// checks get it as TMPDIR, and it is the only temp folder of the profile
	// that can hold their unix sockets.
	dir string
	// env is the environment of each check: TMPDIR, GOPROXY (see goProxy),
	// and an xcrun_db in dir. With that cache, the xcrun shims of a check,
	// such as /usr/bin/git, do not need the cache of the user, which the
	// profile denies. A shim that misses a cache that it cannot write prints
	// an error, which would fail the committed check. Only the processes of
	// the sandbox get this env.
	env []string
	// err is why Loam cannot sandbox the checks. Then each check fails and
	// does not run: a check runs code that the session wrote, and the gate
	// works outside the sandbox of the session.
	err error
}

// userXcrunCache is the cache of the xcrun shims of the user, for tests.
var userXcrunCache = sandbox.XcrunCache

// seedXcrunCache copies the cache of the user to cache, so the shims of a
// check find their tools as they do outside the sandbox. A shim that misses
// the cache runs xcodebuild to fill it, which is slow and, in a sandbox,
// prints errors.
func seedXcrunCache(cache string) {
	if src := userXcrunCache(); src != "" {
		if b, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(cache, b, 0o600)
		}
	}
}

// goProxy is the module cache of Go as a file proxy. The profile denies the
// network, and go run of a module at a version asks the proxy if the module
// is deprecated, also when the module is in the cache. With this proxy, Go
// takes each module that the session fetched from the cache. goProxy returns
// "" when it cannot name the cache as one entry of GOPROXY.
func goProxy() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	dir := filepath.Join(sandbox.GoModCache(home, os.Getenv), "cache", "download")
	// A comma or a pipe splits the list of GOPROXY.
	if !filepath.IsAbs(dir) || strings.ContainsAny(dir, ",|") {
		return ""
	}
	return (&url.URL{Scheme: "file", Path: dir}).String()
}

// close removes the folder of the gate.
func (b checkBox) close() {
	if b.dir != "" {
		_ = os.RemoveAll(b.dir)
	}
}

// sandboxProbeTimeout limits the start of the sandbox with no check.
const sandboxProbeTimeout = 10 * time.Second

// gateRoots are the folders that can hold the folder of the gate, in order.
// /tmp comes first: it keeps the path of a socket in the folder short. A
// process in a sandbox, such as a check of another gate, can have no write
// access to /tmp, so the temp folder of the process comes next. A var, for
// tests.
var gateRoots = func() []string { return []string{"/tmp", os.TempDir()} }

// makeGateDir makes the folder of the gate, with mode 0700, in the first of
// roots that lets it. The folder is absolute, also when a root, such as a
// TMPDIR, is relative: each check runs in the run folder, not here.
func makeGateDir(roots ...string) (string, error) {
	var errs []error
	for _, root := range roots {
		abs, err := filepath.Abs(root)
		if err == nil {
			var dir string
			if dir, err = os.MkdirTemp(abs, "loam-gate-"); err == nil {
				return dir, nil
			}
		}
		errs = append(errs, err)
	}
	return "", errors.Join(errs...)
}

// newCheckBox builds the rules of the run as a Seatbelt profile. Loam passes
// the profile to sandbox-exec with -p, not in a file, so no check can change
// the profile of the next one. It then starts the sandbox once with no
// check, so that a sandbox that cannot start, as in a process that is
// already in a sandbox, fails the gate and not each check.
func newCheckBox(s *store.Store, r store.Run) checkBox {
	if err := sandbox.Available(); err != nil {
		return checkBox{err: err}
	}
	rules, err := session.RunRules(s, r)
	if err != nil {
		return checkBox{err: err}
	}
	dir, err := makeGateDir(gateRoots()...)
	if err != nil {
		return checkBox{err: fmt.Errorf("make the folder of the checks: %w", err)}
	}
	box := checkBox{exec: sandbox.Exec(), dir: dir}
	if box.profile, err = rules.Profile(append([]string{dir}, sandbox.Temps()...)...); err != nil {
		box.close()
		return checkBox{err: err}
	}
	ctx, cancel := context.WithTimeout(context.Background(), sandboxProbeTimeout)
	defer cancel()
	if out, err := exec.CommandContext(ctx, box.exec, "-p", box.profile, "/usr/bin/true").CombinedOutput(); err != nil {
		box.close()
		return checkBox{err: fmt.Errorf("sandbox-exec cannot start the sandbox: %v %s", err, strings.TrimSpace(string(out)))}
	}
	// Not xcrun_db: the profile denies that name in each temp folder.
	cache := filepath.Join(dir, "xcrun-cache")
	seedXcrunCache(cache)
	box.env = append(os.Environ(), "TMPDIR="+dir, "xcrun_db="+cache)
	if p := goProxy(); p != "" {
		box.env = append(box.env, "GOPROXY="+p)
	}
	return box
}

// runCheck runs one check as sh -c in dir, in the sandbox of box. When ctx
// has ended, as at the end of the gate budget, or when box has no sandbox,
// the check fails and does not run.
func runCheck(ctx context.Context, dir string, box checkBox, c store.Check) checkResult {
	if ctx.Err() != nil {
		return checkResult{check: c, exit: -1, output: "Loam did not run the check: the checks ran out of time.",
			timeout: "did not run, because the gate ran out of time"}
	}
	if box.err != nil {
		return checkResult{check: c, exit: -1, output: "Loam did not run the check, because it could not sandbox it: " + box.err.Error()}
	}
	parent := ctx
	ctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, box.exec, "-p", box.profile, "sh", "-c", c.Command)
	cmd.Dir, cmd.Env = dir, box.env
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
		res.timeout = "did not end before the gate ran out of time"
	case ctx.Err() != nil:
		res.passed, res.exit = false, -1
		res.output += fmt.Sprintf("\nThe check did not end in %s.", shortDuration(checkTimeout))
		res.timeout = "did not end in " + shortDuration(checkTimeout)
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

// committedScript returns the script of the committed check. It fails when
// git status --porcelain prints a line. It reads stdout only, because a tool
// that git starts, such as an xcrun shim, can print a warning on stderr. The
// output still has that warning, and the error of a git that fails. When
// gateDir is inside dir, the script leaves that folder out: the checks keep
// their cache there, and Loam removes it after the gate.
func committedScript(dir, gateDir string) string {
	status := "git status --porcelain"
	if rel, ok := insideDir(dir, gateDir); ok {
		status += " -- . " + shellQuote(":(exclude,literal)"+rel)
	}
	return `s=$(` + status + `) || exit; [ -z "$s" ] && exit; ` +
		`printf 'These files are not committed. Commit them, or add them to .gitignore:\n%s\n' "$s"; exit 1`
}

// insideDir returns the path of sub relative to dir, when sub is a folder
// below dir. Both paths are resolved, so a link does not hide the match.
func insideDir(dir, sub string) (string, bool) {
	if sub == "" {
		return "", false
	}
	rel, err := filepath.Rel(sandbox.Real(dir), sandbox.Real(sub))
	if err != nil || rel == "." || rel == ".." || filepath.IsAbs(rel) ||
		strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}

// shellQuote quotes s for sh.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// committed checks that git status in dir shows no work.
func committed(ctx context.Context, dir string, box checkBox) checkResult {
	c := store.Check{Name: CommittedCheck, Command: "git status --porcelain"}
	res := runCheck(ctx, dir, box, store.Check{Name: c.Name, Command: committedScript(dir, box.dir)})
	res.check = c
	return res
}

// reason is the text that a blocked stop sends to the session.
func reason(r store.Run, g gateResult) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Loam gate: %d of %d checks failed (try %d of %d). Fix the failures, then end your turn. Loam runs the checks again.\n%s",
		len(g.failed), len(g.results), r.Tries, r.MaxTries, checksLine(len(g.results) > 1, leaveChecks)) // each gate has the committed check
	for _, f := range g.failed {
		fmt.Fprintf(&b, "\n## %s: `%s` (exit %d)\n%s\n", f.check.Name, f.check.Command, f.exit, Tail(f.output, reasonTail))
	}
	return b.String()
}

// timeoutReason is the text that a blocked stop sends to the session when
// the gate ran out of time, as why says.
func timeoutReason(why string) string {
	return "Loam gate: " + why + ". That is not a failure of your work, so no try counts. " +
		"End your turn now and change nothing: Loam then runs the checks again."
}

// failedNames joins the names of the failed checks.
func failedNames(g gateResult) string {
	names := make([]string, len(g.failed))
	for i, f := range g.failed {
		names[i] = f.check.Name
	}
	return strings.Join(names, ", ")
}

// Tail returns the last n lines of text, after a line that counts the lines
// that it cuts.
func Tail(text string, n int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(lines) > n {
		lines = append([]string{fmt.Sprintf("(%d earlier lines cut)", len(lines)-n)}, lines[len(lines)-n:]...)
	}
	return strings.Join(lines, "\n")
}
