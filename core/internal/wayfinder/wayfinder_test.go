package wayfinder_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/GregorMcC/loam/core/internal/wayfinder"
)

// writeMap writes a map with its tickets, and returns the path of the map.
func writeMap(t *testing.T, tickets map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "issues"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, text := range tickets {
		if err := os.WriteFile(filepath.Join(dir, "issues", name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m := filepath.Join(dir, "map.md")
	if err := os.WriteFile(m, []byte("# A map\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return m
}

const open135 = "Map: ../map.md\nType: task\nStatus: open\nBlocked by: none\n\n# Driver scenario: quit during a merge\n\n## Question\n"

func TestTicketsListsTheOpenTicketsInNumberOrder(t *testing.T) {
	m := writeMap(t, map[string]string{
		"136-sheet-in-full-screen.md": "Status: open\nBlocked by: 135\n\n# Driver scenario: a sheet in full screen\n",
		"135-quit-during-a-merge.md":  open135,
		"99-home-space.md":            "Status: resolved\n\n# A Home space\n",
		"9-early.md":                  "Status: Open\n\n# An early ticket\n",
		"notes.txt":                   "not a ticket",
	})
	got, err := wayfinder.Tickets(m)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("%+v", got)
	}
	if got[0].Key != "map 9" || got[1].Key != "map 135" || got[2].Key != "map 136" {
		t.Fatalf("order %+v", got)
	}
	g := got[1]
	if g.Title != "Driver scenario: quit during a merge" || g.Status != "Open" || g.BlockedBy != "" ||
		g.Path != filepath.Join(filepath.Dir(m), "issues", "135-quit-during-a-merge.md") {
		t.Fatalf("%+v", g)
	}
	if got[2].Status != "Blocked by 135" || got[2].BlockedBy != "135" {
		t.Fatalf("%+v", got[2])
	}
}

func TestTicketsOfAMapWithNoIssuesFolderIsEmpty(t *testing.T) {
	m := filepath.Join(t.TempDir(), "map.md")
	got, err := wayfinder.Tickets(m)
	if err != nil || len(got) != 0 {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestReadTicketReadsOneFile(t *testing.T) {
	m := writeMap(t, map[string]string{"135-quit-during-a-merge.md": open135})
	got, err := wayfinder.ReadTicket(filepath.Join(filepath.Dir(m), "issues", "135-quit-during-a-merge.md"))
	if err != nil || got.Key != "map 135" || got.Title != "Driver scenario: quit during a merge" {
		t.Fatalf("%+v %v", got, err)
	}
	if got.Text != "## Question" || got.Modified.IsZero() {
		t.Fatalf("text %q modified %v", got.Text, got.Modified)
	}
	// A file with no title is not a ticket.
	bad := filepath.Join(filepath.Dir(m), "issues", "200-empty.md")
	if err := os.WriteFile(bad, []byte("Status: open\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := wayfinder.ReadTicket(bad); err == nil {
		t.Fatal("a file with no title read as a ticket")
	}
}
