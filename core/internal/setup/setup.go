// Package setup holds the one-time setup of Loam for Claude Code.
//
// Setup checks each step, asks before it does the step, and is safe to run
// again. It edits no settings file. It reads ~/.claude.json only to see if
// Claude Code already trusts the plots folder.
package setup

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/GregorMcC/loam/core/internal/claudebin"
	"github.com/GregorMcC/loam/core/internal/store"
)

// ServerName is the name of the MCP server in Claude Code.
const ServerName = "loam"

// AllowRules are the permission rules for the read tools. A session that Loam
// did not start needs them to read without a prompt.
var AllowRules = []string{
	"mcp__loam__list_plots",
	"mcp__loam__get_plot",
	"mcp__loam__get_changes",
}

// Options sets how [Run] works.
type Options struct {
	// Binary is the absolute path to the loam binary.
	Binary string
	// Yes answers yes to every question.
	Yes bool
	In  io.Reader
	Out io.Writer
	// Stdin, Stdout, and Stderr connect the claude of the trust step. Nil means the process stdio.
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

// Run does the setup steps.
func Run(o Options) error {
	if !filepath.IsAbs(o.Binary) {
		return fmt.Errorf("the loam path must be absolute: %q", o.Binary)
	}
	claude, err := claudebin.Find()
	if err != nil {
		return errors.New("claude is not on PATH. Install Claude Code, then run loam setup again")
	}
	home, err := store.Home()
	if err != nil {
		return err
	}
	plots := filepath.Join(home, "plots")
	if err := os.MkdirAll(plots, 0o700); err != nil {
		return err
	}
	in := bufio.NewReader(o.In)
	s := &runner{o: o, in: in, claude: claude}

	if err := s.registerStep(); err != nil {
		return err
	}
	if err := s.trustStep(plots); err != nil {
		return err
	}
	fmt.Fprintln(o.Out, "\nAllow rules for the read tools")
	fmt.Fprintln(o.Out, "Sessions that Loam did not start need these rules to read without a prompt.")
	fmt.Fprintln(o.Out, "Add them to the permissions.allow list in your Claude Code settings. Loam does not edit that file.")
	for _, r := range AllowRules {
		fmt.Fprintf(o.Out, "  %q\n", r)
	}
	return nil
}

type runner struct {
	o      Options
	in     *bufio.Reader
	claude string
}

// ask returns true if the person says yes. At end of input the answer is no.
func (s *runner) ask(q string) bool {
	if s.o.Yes {
		return true
	}
	fmt.Fprintf(s.o.Out, "%s [y/N] ", q)
	line, _ := s.in.ReadString('\n')
	a := strings.ToLower(strings.TrimSpace(line))
	return a == "y" || a == "yes"
}

func (s *runner) claudeCmd(dir string, args ...string) *exec.Cmd {
	c := exec.Command(s.claude, args...)
	c.Dir = dir
	return c
}

func (s *runner) registerStep() error {
	out := s.o.Out
	registered, current := mcpState(s.claude, s.o.Binary)
	if current {
		fmt.Fprintln(out, "MCP server: done (loam is registered with this binary)")
		return nil
	}
	q := fmt.Sprintf("Register the MCP server %q at user scope with %s?", ServerName, s.o.Binary)
	if registered {
		q = fmt.Sprintf("The MCP server %q points at a different binary. Replace it with %s?", ServerName, s.o.Binary)
	}
	if !s.ask(q) {
		fmt.Fprintln(out, "MCP server: skipped")
		return nil
	}
	if registered {
		if b, err := s.claudeCmd("", "mcp", "remove", "--scope", "user", ServerName).CombinedOutput(); err != nil {
			return fmt.Errorf("claude mcp remove failed: %v: %s", err, strings.TrimSpace(string(b)))
		}
	}
	if b, err := s.claudeCmd("", "mcp", "add", "--scope", "user", ServerName, "--", s.o.Binary, "mcp").CombinedOutput(); err != nil {
		return fmt.Errorf("claude mcp add failed: %v: %s", err, strings.TrimSpace(string(b)))
	}
	fmt.Fprintln(out, "MCP server: registered")
	return nil
}

func (s *runner) trustStep(plots string) error {
	out := s.o.Out
	if trusted(plots) {
		fmt.Fprintln(out, "Trust for the plots folder: done")
		return nil
	}
	q := fmt.Sprintf("Start claude in %s so you can accept the trust prompt? Choose Yes, then exit claude.", plots)
	if !s.ask(q) {
		fmt.Fprintln(out, "Trust for the plots folder: skipped")
		return nil
	}
	c := s.claudeCmd(plots)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	if s.o.Stdin != nil {
		c.Stdin = s.o.Stdin
	}
	if s.o.Stdout != nil {
		c.Stdout = s.o.Stdout
	}
	if s.o.Stderr != nil {
		c.Stderr = s.o.Stderr
	}
	if err := c.Run(); err != nil {
		return fmt.Errorf("claude exited with an error: %w", err)
	}
	fmt.Fprintln(out, "Trust for the plots folder: claude ran")
	return nil
}

// namesBinary reports whether the output holds the path as a whole word.
func namesBinary(out, bin string) bool {
	return regexp.MustCompile(`(^|\s)` + regexp.QuoteMeta(bin) + `(\s|$)`).MatchString(out)
}

// trusted reads ~/.claude.json and reports whether Claude Code recorded trust
// for the folder. A missing or unreadable file means not trusted.
func trusted(dir string) bool {
	h := os.Getenv("CLAUDE_CONFIG_DIR")
	if h == "" {
		var err error
		if h, err = os.UserHomeDir(); err != nil {
			return false
		}
	}
	b, err := os.ReadFile(filepath.Join(h, ".claude.json"))
	if err != nil {
		return false
	}
	var cfg struct {
		Projects map[string]struct {
			Trusted bool `json:"hasTrustDialogAccepted"`
		} `json:"projects"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return false
	}
	keys := []string{dir}
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		keys = append(keys, r)
	}
	for _, k := range keys {
		if cfg.Projects[k].Trusted {
			return true
		}
	}
	return false
}

// mcpState asks claude if the loam MCP server is registered, and if it
// points at the binary.
func mcpState(claude, binary string) (registered, current bool) {
	b, err := exec.Command(claude, "mcp", "get", ServerName).Output()
	if err != nil {
		return false, false
	}
	return true, namesBinary(string(b), binary)
}

// Step is one setup step in a [Report].
type Step struct {
	ID     string `json:"id"`
	Done   bool   `json:"done"`
	Detail string `json:"detail,omitempty"`
}

// Report is the result of [Check].
type Report struct {
	// OK is true when every step is done.
	OK    bool   `json:"ok"`
	Steps []Step `json:"steps"`
}

// Check reports each setup step as done or not done. It asks nothing and
// changes nothing: it makes no folder, writes no file, and runs only
// "claude mcp get".
func Check(binary string) (Report, error) {
	home, err := store.Home()
	if err != nil {
		return Report{}, err
	}
	mcp := Step{ID: "mcp"}
	if claude, err := claudebin.Find(); err != nil {
		mcp.Detail = "claude is not on PATH"
	} else {
		registered, current := mcpState(claude, binary)
		mcp.Done = current
		switch {
		case current:
		case registered:
			mcp.Detail = "the loam MCP server points at a different binary"
		default:
			mcp.Detail = "the loam MCP server is not registered"
		}
	}
	trust := Step{ID: "trust", Done: trusted(filepath.Join(home, "plots"))}
	if !trust.Done {
		trust.Detail = "Claude Code has not trusted the plots folder"
	}
	r := Report{Steps: []Step{mcp, trust}}
	r.OK = mcp.Done && trust.Done
	return r, nil
}
