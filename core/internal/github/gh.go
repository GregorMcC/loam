package github

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// ghEnv names the gh binary to run, with no search. Tests set it, so no test
// runs the real gh.
const ghEnv = "LOAM_GH"

// installPaths are the places where the gh installers put gh: Homebrew on
// Apple silicon, Homebrew on Intel, and MacPorts. Loam.app runs loam with
// the short PATH of an app that the Finder starts, which often has none of
// them.
var installPaths = []string{"/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"}

// ghTimeout stops a gh call that waits on the network.
const ghTimeout = 15 * time.Second

// ghActionTimeout stops a gh command that acts on GitHub, such as a merge.
// gh makes more than one request for such a command, and a merge that stops
// too soon leaves Loam in doubt about the result.
const ghActionTimeout = time.Minute

// ghWaitDelay is how long Loam waits for the output of a gh call after it
// stops gh, in case a child process of gh still holds the pipes.
const ghWaitDelay = time.Second

// ghExitAuth is the exit code of gh when it has no sign-in.
const ghExitAuth = 4

// Find returns the absolute path of gh: LOAM_GH when it is set, else from
// PATH, else from an install folder.
func Find() (string, error) {
	if p := os.Getenv(ghEnv); p != "" {
		if !executable(p) {
			return "", ErrGHMissing
		}
		return p, nil
	}
	if p, err := exec.LookPath("gh"); err == nil {
		return filepath.Abs(p)
	}
	for _, p := range installPaths {
		if executable(p) {
			return p, nil
		}
	}
	return "", ErrGHMissing
}

func executable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}

// Client asks GitHub through gh.
type Client struct {
	gh string
}

// NewClient finds gh. It fails with [ErrGHMissing] when gh is not installed.
func NewClient() (*Client, error) {
	gh, err := Find()
	if err != nil {
		return nil, err
	}
	return &Client{gh: gh}, nil
}

// query runs one GraphQL query and decodes its data into out.
func (c *Client) query(ctx context.Context, query string, vars map[string]any, out any) error {
	body, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return err
	}
	stdout, err := c.run(ctx, ghTimeout, body, "api", "graphql", "--hostname", host, "--input", "-")
	if err != nil {
		return readError(err)
	}
	var resp struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(stdout, &resp); err != nil {
		return fmt.Errorf("%w: gh gave an answer that is not JSON: %v", ErrOffline, err)
	}
	if err := json.Unmarshal(resp.Data, out); err != nil {
		return fmt.Errorf("%w: gh gave an answer that Loam cannot read: %v", ErrOffline, err)
	}
	return nil
}

// run runs gh with args, with stdin as its input, and returns what gh printed
// on stdout. The call stops after timeout, or when ctx ends.
//
// A cancelled ctx gives the error of the context: the caller stopped the
// call, and GitHub did not fail. A call that does not end in time gives
// [ErrOffline]. A missing gh gives [ErrGHMissing], and a gh with no valid
// sign-in gives [ErrSignedOut]. Any other failure is a *ghFailure, and the
// caller says what it means.
func (c *Client) run(ctx context.Context, timeout time.Duration, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.gh, args...)
	cmd.WaitDelay = ghWaitDelay
	cmd.Stdin = bytes.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err == nil {
		return stdout.Bytes(), nil
	}
	switch ctxErr := ctx.Err(); {
	case errors.Is(ctxErr, context.DeadlineExceeded):
		return nil, fmt.Errorf("%w: gh did not answer in time", ErrOffline)
	case ctxErr != nil:
		return nil, fmt.Errorf("gh stopped: %w", ctxErr)
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrGHMissing
	}
	var ee *exec.ExitError
	if (errors.As(err, &ee) && ee.ExitCode() == ghExitAuth) || strings.Contains(stderr.String(), "HTTP 401") {
		return nil, ErrSignedOut
	}
	return nil, &ghFailure{err: err, stderr: stderr.String()}
}

// ghFailure is a gh call that ended with an error that [Client.run] does not
// sort: GitHub refused the request, or gh could not reach GitHub.
type ghFailure struct {
	err    error
	stderr string
}

func (f *ghFailure) Error() string { return f.message() }

// ghFailureMark is what gh prints before the message of a failed command,
// such as gh pr merge, when its output is not a terminal.
const ghFailureMark = "X "

// message is the first line that gh printed on stderr: the message of
// GitHub, with no "gh: " or failure mark before it. Later lines are hints for
// the flags of gh, which Loam does not have.
func (f *ghFailure) message() string {
	msg, _, _ := strings.Cut(strings.TrimSpace(f.stderr), "\n")
	msg = strings.TrimPrefix(strings.TrimPrefix(msg, "gh: "), ghFailureMark)
	if msg == "" {
		msg = f.err.Error()
	}
	return msg
}

// says reports whether gh printed one of the texts on stderr.
func (f *ghFailure) says(texts ...string) bool {
	return slices.ContainsFunc(texts, func(text string) bool { return strings.Contains(f.stderr, text) })
}

// rateLimited reports whether GitHub refused the request for its rate
// limit. A rate limit can come as an HTTP error or as a GraphQL error, and
// GitHub sends some of them with HTTP 403.
func (f *ghFailure) rateLimited() bool {
	return strings.Contains(strings.ToLower(f.stderr), "rate limit") || f.says("HTTP 429")
}

// noAccessText is the text in a gh error that says that gh cannot read the
// repo: HTTP 403 or 404, a GraphQL error for a repo that gh cannot see, or an
// organization that needs SAML SSO for the sign-in of gh.
var noAccessText = []string{"HTTP 403", "HTTP 404", "Could not resolve to a Repository", "SAML", "SSO"}

// readError turns a failed gh call that reads from GitHub into one of the
// errors of this package. gh api prints "gh: " and the message of GitHub on
// stderr, for an HTTP error and for a GraphQL error. Loam looks for a rate
// limit before it looks for HTTP 403.
func readError(err error) error {
	var f *ghFailure
	if !errors.As(err, &f) {
		return err
	}
	switch {
	case f.rateLimited():
		return fmt.Errorf("%w: %s", ErrRateLimited, f.message())
	case f.says(noAccessText...):
		return fmt.Errorf("%w: %s", ErrNoAccess, f.message())
	}
	return fmt.Errorf("%w: %s", ErrOffline, f.message())
}
