// Package seed renders a plot's seed CLAUDE.md from the store and writes it
// to <LOAM_HOME>/plots/<id>/CLAUDE.md.
//
// Every write path calls [AfterChange] after a change commits. `loam start` calls
// [Write] before it starts a session. The store is the source. Loam never
// reads the content of a seed back. It reads only the revision on line 1.
package seed

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unicode"

	"github.com/GregorMcC/loam/core/internal/linkkind"
	"github.com/GregorMcC/loam/core/internal/store"
)

const (
	revisionPrefix = "<!-- loam-revision: "
	revisionSuffix = " -->"
)

// Path returns the seed file path of a plot.
func Path(s *store.Store, plotID string) string {
	return filepath.Join(s.PlotDir(plotID), "CLAUDE.md")
}

// Write reads the plot from the store and writes its seed. It never replaces
// a seed with a newer revision.
func Write(s *store.Store, plotID string) error {
	p, err := s.GetPlot(plotID)
	if err != nil {
		return err
	}
	return WritePlot(s, p)
}

// WritePlot writes the seed of a plot that the caller already read, for
// example Result.Plot from a change. It never replaces a seed with a newer
// revision. A seed with the same revision is written again.
func WritePlot(s *store.Store, p store.Plot) error {
	path := Path(s, p.ID)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// Lock the plot folder so that the revision check and the rename are one
	// step for concurrent writers (CLI, MCP server, and start).
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	if err := syscall.Flock(int(d.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(d.Fd()), syscall.LOCK_UN)
	if cur, err := ReadRevision(path); err == nil && cur > p.Revision {
		return nil
	}
	tmp, err := os.CreateTemp(dir, ".CLAUDE.md.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(Render(p)); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// AfterChange writes the seed of res.Plot after a change committed. It does
// nothing when the change wrote nothing. A failed write is a warning on res,
// not an error: the store is the source, and the next write or start writes
// the seed again.
func AfterChange(s *store.Store, res *store.Result) {
	if res.ChangeID == 0 {
		return
	}
	if err := WritePlot(s, res.Plot); err != nil {
		res.Warnings = append(res.Warnings, "the seed was not written: "+err.Error())
	}
}

// ReadRevision returns the revision on the first line of a seed file. It
// returns an error when the file is missing or has no revision line.
func ReadRevision(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		return 0, err
	}
	line = strings.TrimRight(line, "\r\n")
	if !strings.HasPrefix(line, revisionPrefix) || !strings.HasSuffix(line, revisionSuffix) {
		return 0, fmt.Errorf("no revision line in %s", path)
	}
	return strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(line, revisionPrefix), revisionSuffix), 10, 64)
}

// Render returns the seed text of a plot.
func Render(p store.Plot) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s%d%s\n", revisionPrefix, p.Revision, revisionSuffix)
	fmt.Fprintf(&b, "# Plot: %s\n\n", oneLine(p.Name))
	fmt.Fprintf(&b, "Loam wrote this file from plot %s. Do not edit it. Loam replaces it when the plot changes.\n\n", p.ID)
	b.WriteString("## How to use this plot\n\n")
	fmt.Fprintf(&b, "- This session belongs to the plot \"%s\". The plot has a brief, repos, and links.\n", oneLine(p.Name))
	b.WriteString("- The plot can change while you work. Before you rely on a plot detail, call `get_plot`.\n")
	b.WriteString("- To change the plot, use the Loam MCP tools (`mcp__loam__*`), not the `loam` CLI. Loam records each change in the change log.\n")
	b.WriteString("- When the work moves on, call `set_where_it_stands` with your proposed text.\n")
	b.WriteString("- A link is a pointer, not content. Fetch a link only when the task needs it, through your own connectors. If you have no connector for a link, tell me.\n")
	b.WriteString("- You can read repos and local links directly.\n")

	parts := []struct{ title, text string }{{"What", p.What}, {"Why", p.Why}, {"Where it stands", p.Where}}
	var brief strings.Builder
	for _, part := range parts {
		if t := strings.TrimSpace(part.text); t != "" {
			fmt.Fprintf(&brief, "\n### %s\n\n%s\n", part.title, t)
		}
	}
	if brief.Len() > 0 {
		b.WriteString("\n## Brief\n")
		b.WriteString(brief.String())
	}
	if len(p.Repos) > 0 {
		b.WriteString("\n## Repos\n\n")
		for _, r := range p.Repos {
			fmt.Fprintf(&b, "- `%s`%s\n", noControl(r.Path), noteSuffix(r.Note))
		}
	}
	if len(p.Links) > 0 {
		b.WriteString("\n## Links\n\n")
		for _, l := range p.Links {
			if linkkind.IsLocal(l.Target) {
				fmt.Fprintf(&b, "- %s: `%s` (local)%s\n", oneLine(l.Label), noControl(linkkind.Expand(l.Target)), noteSuffix(l.Note))
			} else {
				fmt.Fprintf(&b, "- [%s](%s)%s\n", oneLine(l.Label), noControl(strings.TrimSpace(l.Target)), noteSuffix(l.Note))
			}
		}
	}
	return b.String()
}

func noteSuffix(note string) string {
	if n := oneLine(note); n != "" {
		return ": " + n
	}
	return ""
}

// noControl turns each control character, such as a newline, into a space. A
// path or a target keeps its other characters, but it cannot start a new line
// of the seed.
func noControl(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
}

// oneLine joins the lines of s so that a list item stays on one line.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }
