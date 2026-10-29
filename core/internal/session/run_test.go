package session_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// TAS-175: a run session works in a sandbox. Its settings deny home and allow
// the repos and the local links of the plot, the git folder, and the caches
// of the stacks that the repos name. A URL link is not a path, so it is not in
// the lists. The sandbox lets Bash write each --add-dir folder, so the session
// adds only the plot folder, which holds the seed, and the sandbox denies
// writes to it.
func TestPrepareRunSandboxesTheSession(t *testing.T) {
	e := setup(t)
	repo, _ := testutil.GitRepo(t)
	other, _ := testutil.GitRepo(t)
	if err := os.WriteFile(filepath.Join(repo, "go.mod"), []byte("module x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	spec := filepath.Join(t.TempDir(), "spec.md")
	p := e.plot(t, store.PlotInput{
		Name:  "Alpha",
		Repos: []store.RepoInput{{Path: repo}, {Path: other}},
		Links: []store.LinkInput{{Label: "Spec", Target: spec}, {Label: "Site", Target: "https://example.com"}},
	})
	plan, err := session.PrepareRun(e.store, store.Run{ID: "r1", PlotID: p.ID, Folder: repo}, "go", "loam", "", "")
	if err != nil {
		t.Fatal(err)
	}
	plotDir := e.store.PlotDir(p.ID)
	if got := argValues(plan.Args, "--add-dir"); !slices.Equal(got, []string{plotDir}) {
		t.Errorf("--add-dir = %q, want only the plot folder %s", got, plotDir)
	}
	files := argValues(plan.Args, "--settings")
	if len(files) != 1 {
		t.Fatalf("args %v have no one --settings", plan.Args)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Permissions struct{ Deny []string }
		Sandbox     struct {
			Enabled, FailIfUnavailable, AllowUnsandboxedCommands bool
			Network                                              struct {
				AllowedDomains  []string
				StrictAllowlist bool
			}
			Filesystem struct{ DenyRead, AllowRead, AllowWrite, DenyWrite []string }
		}
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	sb := got.Sandbox
	if !sb.Enabled || !sb.FailIfUnavailable || sb.AllowUnsandboxedCommands || !sb.Network.StrictAllowlist {
		t.Errorf("sandbox locks = %+v, want enabled, failIfUnavailable, no unsandboxed commands, strict allowlist", sb)
	}
	home, _ := os.UserHomeDir()
	if !slices.Equal(sb.Filesystem.DenyRead, []string{realpath(t, home)}) {
		t.Errorf("denyRead = %q, want the home folder", sb.Filesystem.DenyRead)
	}
	real := realpath(t, repo)
	git := filepath.Join(real, ".git")
	for _, want := range []string{real, git, filepath.Join(realpath(t, filepath.Dir(spec)), "spec.md")} {
		if !slices.Contains(sb.Filesystem.AllowRead, want) {
			t.Errorf("allowRead = %q, want %s", sb.Filesystem.AllowRead, want)
		}
	}
	for _, want := range []string{real, git} {
		if !slices.Contains(sb.Filesystem.AllowWrite, want) {
			t.Errorf("allowWrite = %q, want %s", sb.Filesystem.AllowWrite, want)
		}
	}
	if !slices.Contains(sb.Filesystem.AllowRead, realpath(t, other)) {
		t.Errorf("allowRead = %q, want the other repo", sb.Filesystem.AllowRead)
	}
	if slices.Contains(sb.Filesystem.AllowWrite, realpath(t, other)) {
		t.Errorf("allowWrite = %q has the other repo", sb.Filesystem.AllowWrite)
	}
	if !slices.Equal(sb.Filesystem.DenyWrite, []string{realpath(t, plotDir)}) {
		t.Errorf("denyWrite = %q, want the plot folder", sb.Filesystem.DenyWrite)
	}
	if slices.Contains(sb.Filesystem.AllowRead, "https://example.com") {
		t.Errorf("allowRead = %q has the URL link", sb.Filesystem.AllowRead)
	}
	if !slices.Contains(sb.Network.AllowedDomains, "proxy.golang.org") {
		t.Errorf("allowedDomains = %q, want the Go proxy", sb.Network.AllowedDomains)
	}
	if !slices.Contains(got.Permissions.Deny, "Read(~/.ssh/**)") {
		t.Errorf("permissions.deny = %q, want the credential paths", got.Permissions.Deny)
	}
}
