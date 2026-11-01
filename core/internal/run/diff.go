package run

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/gitcmd"
	"github.com/GregorMcC/loam/core/internal/store"
)

// diffLineCap is the most lines of one file that a diff holds. The counts
// of a longer file stay right, and the file is Truncated.
const diffLineCap = 3000

// DiffResult is the work of a run: the commits on its branch since its base.
type DiffResult struct {
	// Base is the commit that the branch started from, and Head is its last
	// commit.
	Base  string     `json:"base"`
	Head  string     `json:"head"`
	Files []DiffFile `json:"files"`
}

// DiffFile is the change to one file. Status is added, modified, deleted,
// or renamed. OldPath is the path before a rename.
type DiffFile struct {
	Path      string     `json:"path"`
	OldPath   string     `json:"old_path,omitempty"`
	Status    string     `json:"status"`
	Added     int        `json:"added"`
	Deleted   int        `json:"deleted"`
	Binary    bool       `json:"binary,omitempty"`
	Truncated bool       `json:"truncated,omitempty"`
	Hunks     []DiffHunk `json:"hunks"`
}

// DiffHunk is one part of a file that changed, with lines of context.
type DiffHunk struct {
	Header   string     `json:"header"`
	OldStart int        `json:"old_start"`
	NewStart int        `json:"new_start"`
	Lines    []DiffLine `json:"lines"`
}

// DiffLine is one line of a hunk. Kind is context, add, or del. Old and New
// are its numbers in the file before and after; a line that is only on one
// side has 0 on the other.
type DiffLine struct {
	Kind string `json:"kind"`
	Old  int    `json:"old,omitempty"`
	New  int    `json:"new,omitempty"`
	Text string `json:"text"`
}

// Diff returns the work that a run committed on its branch, from the commit
// where the branch left its base to the head of the worktree. For a Ready
// run with a PR, the diff ends at the head that Loam pushed, so it is the
// work that a land merges, and not a commit after it.
func Diff(ctx context.Context, s *store.Store, id string) (DiffResult, error) {
	r, err := s.GetRun(id)
	if err != nil {
		return DiffResult{}, err
	}
	w, err := s.GetWorktree(r.WorktreeID)
	if err != nil {
		return DiffResult{}, fmt.Errorf("the worktree of the run is gone, so it has no diff: %w", store.ErrInvalid)
	}
	head, err := gitOut(ctx, r.Folder, "rev-parse", "HEAD")
	if err != nil {
		return DiffResult{}, fmt.Errorf("could not read the head of %s: %w", r.Folder, err)
	}
	if r.State == store.RunReady && r.PR != nil {
		if head, err = pushedHead(ctx, r.Folder, w.Branch); err != nil {
			return DiffResult{}, fmt.Errorf("could not read the pushed head of %s, so the diff could show work that the PR does not have: %w", w.Branch, err)
		}
	}
	base, err := gitOut(ctx, r.Folder, "merge-base", w.Base, head)
	if err != nil || w.Base == "" {
		return DiffResult{}, fmt.Errorf("could not find where the branch left its base %q: %w", w.Base, store.ErrInvalid)
	}
	// Fixed prefixes and no quotes, whatever the git config of the repo says.
	out, err := gitcmd.Command(ctx, r.Folder, "-c", "core.quotePath=off", "diff",
		"--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/", base, head).Output()
	if err != nil {
		return DiffResult{}, fmt.Errorf("git diff failed in %s: %w", r.Folder, err)
	}
	return DiffResult{Base: base, Head: head, Files: parseDiff(string(out), diffLineCap)}, nil
}

var hunkHeader = regexp.MustCompile(`^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@`)

// parseDiff reads git diff output. A file keeps at most lineCap lines.
func parseDiff(text string, lineCap int) []DiffFile {
	files := []DiffFile{}
	var f *DiffFile
	var h *DiffHunk
	oldLine, newLine, kept := 0, 0, 0
	for _, line := range strings.Split(strings.TrimSuffix(text, "\n"), "\n") {
		if rest, ok := strings.CutPrefix(line, "diff --git "); ok {
			files = append(files, DiffFile{Path: headerPath(rest), Status: "modified", Hunks: []DiffHunk{}})
			f, h, kept = &files[len(files)-1], nil, 0
			continue
		}
		if f == nil {
			continue
		}
		if m := hunkHeader.FindStringSubmatch(line); m != nil {
			oldLine, _ = strconv.Atoi(m[1])
			newLine, _ = strconv.Atoi(m[2])
			f.Hunks = append(f.Hunks, DiffHunk{Header: line, OldStart: oldLine, NewStart: newLine, Lines: []DiffLine{}})
			h = &f.Hunks[len(f.Hunks)-1]
			continue
		}
		if h == nil {
			fileHeader(f, line)
			continue
		}
		var l DiffLine
		switch {
		case strings.HasPrefix(line, "+"):
			l = DiffLine{Kind: "add", New: newLine, Text: line[1:]}
			f.Added++
			newLine++
		case strings.HasPrefix(line, "-"):
			l = DiffLine{Kind: "del", Old: oldLine, Text: line[1:]}
			f.Deleted++
			oldLine++
		case strings.HasPrefix(line, " "):
			l = DiffLine{Kind: "context", Old: oldLine, New: newLine, Text: line[1:]}
			oldLine++
			newLine++
		default:
			continue // "\ No newline at end of file"
		}
		if kept == lineCap {
			f.Truncated = true
			continue
		}
		h.Lines = append(h.Lines, l)
		kept++
	}
	return files
}

// fileHeader reads one line of the header of a file, before its first hunk.
func fileHeader(f *DiffFile, line string) {
	switch {
	case strings.HasPrefix(line, "new file mode"):
		f.Status = "added"
	case strings.HasPrefix(line, "deleted file mode"):
		f.Status = "deleted"
	case strings.HasPrefix(line, "rename from "):
		f.Status, f.OldPath = "renamed", unquote(strings.TrimPrefix(line, "rename from "))
	case strings.HasPrefix(line, "rename to "):
		f.Path = unquote(strings.TrimPrefix(line, "rename to "))
	case strings.HasPrefix(line, "+++ b/"):
		f.Path = unquote(strings.TrimPrefix(line, "+++ b/"))
	case strings.HasPrefix(line, "--- a/") && f.Status == "deleted":
		f.Path = unquote(strings.TrimPrefix(line, "--- a/"))
	case strings.HasPrefix(line, "Binary files "):
		f.Binary = true
	}
}

// headerPath is the path in "a/<path> b/<path>", the rest of a diff --git
// line, when both paths are the same. The --- and +++ lines, or a rename,
// give the path of other files.
func headerPath(rest string) string {
	if n := len(rest); n > 5 && n%2 == 1 {
		a, b := rest[:n/2], rest[n/2+1:]
		if strings.HasPrefix(a, "a/") && strings.HasPrefix(b, "b/") && a[2:] == b[2:] {
			return a[2:]
		}
	}
	return ""
}

// unquote reads a path as git writes it: in quotes when it has a special
// character, and with a tab at the end when it has a space.
func unquote(path string) string {
	path = strings.TrimSuffix(path, "\t")
	if strings.HasPrefix(path, `"`) {
		if p, err := strconv.Unquote(path); err == nil {
			return p
		}
	}
	return path
}
