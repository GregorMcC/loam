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
	ctx, cancel := context.WithTimeout(ctx, ghTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.gh, "api", "graphql", "--hostname", host, "--input", "-")
	cmd.Stdin = bytes.NewReader(body)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return ghError(ctx, err, stderr.String())
	}
	var resp struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &resp); err != nil {
		return fmt.Errorf("%w: gh gave an answer that is not JSON: %v", ErrOffline, err)
	}
	if err := json.Unmarshal(resp.Data, out); err != nil {
		return fmt.Errorf("%w: gh gave an answer that Loam cannot read: %v", ErrOffline, err)
	}
	return nil
}

// ghError turns a failed gh call into one of the errors of this package.
// GitHub sends a rate limit as an HTTP error or as a GraphQL error of type
// RATE_LIMITED. gh prints the message of either one on stderr.
func ghError(ctx context.Context, err error, stderr string) error {
	if ctx.Err() != nil {
		return fmt.Errorf("%w: gh did not answer in time", ErrOffline)
	}
	if errors.Is(err, fs.ErrNotExist) {
		return ErrGHMissing
	}
	var ee *exec.ExitError
	if (errors.As(err, &ee) && ee.ExitCode() == ghExitAuth) || strings.Contains(stderr, "HTTP 401") {
		return ErrSignedOut
	}
	msg, _, _ := strings.Cut(strings.TrimSpace(strings.TrimPrefix(stderr, "gh: ")), "\n")
	if msg == "" {
		msg = err.Error()
	}
	if strings.Contains(strings.ToLower(stderr), "rate limit") || strings.Contains(stderr, "HTTP 429") {
		return fmt.Errorf("%w: %s", ErrRateLimited, msg)
	}
	return fmt.Errorf("%w: %s", ErrOffline, msg)
}
