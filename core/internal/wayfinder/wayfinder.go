// Package wayfinder reads the tickets of a wayfinder map: a map.md file with
// an issues folder next to it, one Markdown file for each ticket. A ticket
// file starts with "Key: value" lines, such as "Status: open" and "Blocked by:
// 135", then a "# Title" line.
package wayfinder

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Ticket is one ticket of a map.
type Ticket struct {
	// Number is the number at the start of the file name, such as "135", or
	// the whole name without ".md" when it has no number.
	Number string
	// Key is "map " and the number, such as "map 135".
	Key   string
	Title string
	// Status is for a person to read: "Open", or "Blocked by 135".
	Status string
	// BlockedBy is the value of the "Blocked by" line, or "" for none.
	BlockedBy string
	// Path is the absolute path of the ticket file.
	Path string
	// Closed is true for a ticket whose status is resolved, done, or closed.
	Closed bool
	// Text is the text of the file after the title line, trimmed.
	Text string
	// Modified is when the file last changed.
	Modified time.Time
}

// closedStatuses are the statuses of a ticket that needs no more work.
var closedStatuses = []string{"resolved", "done", "closed", "dropped", "wontfix"}

// IsMap reports whether path names a map: a file called map.md.
func IsMap(path string) bool {
	return filepath.Base(path) == "map.md"
}

// Tickets returns the open tickets of the map at mapPath, in number order. A
// map with no issues folder has none. A file that is not a ticket is left out.
func Tickets(mapPath string) ([]Ticket, error) {
	dir := filepath.Join(filepath.Dir(mapPath), "issues")
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []Ticket
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".md" {
			continue
		}
		t, err := ReadTicket(filepath.Join(dir, e.Name()))
		if err != nil || t.Closed {
			continue
		}
		out = append(out, t)
	}
	slices.SortFunc(out, func(a, b Ticket) int { return compareNumbers(a.Number, b.Number) })
	return out, nil
}

// ReadTicket reads one ticket file. A file that is not in an issues folder,
// or has no "# Title" line, is not a ticket.
func ReadTicket(path string) (Ticket, error) {
	if filepath.Base(filepath.Dir(path)) != "issues" || filepath.Ext(path) != ".md" {
		return Ticket{}, fmt.Errorf("%s is not a .md file in an issues folder", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return Ticket{}, err
	}
	info, err := os.Stat(path)
	if err != nil {
		return Ticket{}, err
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Ticket{}, err
	}
	stem := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	number := stem
	if i := strings.IndexFunc(stem, func(r rune) bool { return !unicode.IsDigit(r) }); i > 0 {
		number = stem[:i]
	}
	t := Ticket{Number: number, Key: "map " + number, Path: abs, Modified: info.ModTime()}
	var status string
	lines := strings.Split(string(data), "\n")
	for n, line := range lines {
		line = strings.TrimSuffix(line, "\r")
		if title, ok := strings.CutPrefix(line, "# "); ok {
			t.Title = strings.TrimSpace(title)
			t.Text = strings.TrimSpace(strings.Join(lines[n+1:], "\n"))
			break
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch strings.ToLower(strings.TrimSpace(key)) {
		case "status":
			status = strings.ToLower(value)
		case "blocked by":
			if !strings.EqualFold(value, "none") {
				t.BlockedBy = value
			}
		}
	}
	if t.Title == "" {
		return Ticket{}, fmt.Errorf("%s has no title line", path)
	}
	t.Closed = slices.Contains(closedStatuses, status)
	switch {
	case t.BlockedBy != "":
		t.Status = "Blocked by " + t.BlockedBy
	case status == "":
		t.Status = "Open"
	default:
		t.Status = strings.ToUpper(status[:1]) + status[1:]
	}
	return t, nil
}

// compareNumbers orders numbers by value, and a name with no number after
// every number.
func compareNumbers(a, b string) int {
	na, errA := strconv.Atoi(a)
	nb, errB := strconv.Atoi(b)
	switch {
	case errA == nil && errB == nil:
		return na - nb
	case errA == nil:
		return -1
	case errB == nil:
		return 1
	}
	return strings.Compare(a, b)
}
