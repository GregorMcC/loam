package mcpserver_test

import (
	"os"
	"os/exec"
	"testing"
)

// gitRepo makes a git repo with an origin remote. Git runs with no global config.
func gitRepo(t *testing.T, origin string) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{{"init", "-q"}, {"remote", "add", "origin", origin}} {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return dir
}

// Ticket 77: add_repo brings the repo's remote as a link, and a plot that has the link gets no second one.
func TestAddRepoAddsTheRemoteAsALink(t *testing.T) {
	e := setup(t, opts{plotEnv: "ALPHA"})
	e.ok("get_plot", nil)
	e.ok("add_repo", map[string]any{"path": gitRepo(t, "git@github.com:me/app.git")})
	p := e.plotNow(e.plot.ID)
	if len(p.Links) != 1 || p.Links[0].Label != "app on GitHub" || p.Links[0].Target != "https://github.com/me/app" {
		t.Fatalf("links %+v", p.Links)
	}
	e.ok("get_plot", nil)
	e.ok("add_repo", map[string]any{"path": gitRepo(t, "https://github.com/me/app.git")})
	if p := e.plotNow(e.plot.ID); len(p.Repos) != 2 || len(p.Links) != 1 {
		t.Fatalf("repos %+v links %+v", p.Repos, p.Links)
	}
}

// Ticket 77: create_plot adds each repo's remote as a link.
func TestCreatePlotAddsTheRemotesAsLinks(t *testing.T) {
	e := setup(t, opts{})
	out := e.ok("create_plot", map[string]any{"name": "Gamma", "what": "w", "why": "y",
		"repos": []map[string]any{{"path": gitRepo(t, "git@gitlab.com:team/web.git")}}})
	p := e.plotNow(idOut(t, out, "plot_id"))
	if len(p.Links) != 1 || p.Links[0].Label != "web on GitLab" || p.Links[0].Target != "https://gitlab.com/team/web" {
		t.Fatalf("links %+v", p.Links)
	}
}
