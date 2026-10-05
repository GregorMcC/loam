package session_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestStartAndResumeRefuseAnArchivedPlot(t *testing.T) {
	e := setup(t)
	main := t.TempDir()
	p := e.plot(t, store.PlotInput{Name: "Alpha", Repos: []store.RepoInput{{Path: main}}})
	if out, err := e.run(t, "start", p.ID, "--session-id", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	os.Remove(os.Getenv("LOAM_FAKE_CLAUDE_OUT"))
	if err := e.store.SetArchived(p.ID, true); err != nil {
		t.Fatal(err)
	}

	for name, args := range map[string][]string{
		"start":  {"start", p.ID, "--session-id", otherID},
		"resume": {"resume", fixedID},
	} {
		out, err := e.run(t, args...)
		if err == nil || !strings.Contains(out, "unarchive first") || !strings.Contains(out, "loam unarchive "+p.ID) {
			t.Errorf("%s: want a refusal that says unarchive first, got %v: %s", name, err, out)
		}
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() != 1 {
			t.Errorf("%s: exit code %d, want 1", name, ee.ExitCode())
		}
		if _, err := os.Stat(os.Getenv("LOAM_FAKE_CLAUDE_OUT")); err == nil {
			t.Errorf("%s: claude started", name)
		}
	}
	if recs, _ := e.store.ListSessions(p.ID); len(recs) != 1 {
		t.Errorf("a refused start left a record: %v", recs)
	}

	// After unarchive, both work.
	if err := e.store.SetArchived(p.ID, false); err != nil {
		t.Fatal(err)
	}
	if out, err := e.run(t, "start", p.ID, "--session-id", otherID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if out, err := e.run(t, "resume", fixedID); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
}
