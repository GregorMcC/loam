package gitremote

import (
	"os"
	"os/exec"
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

func TestWebURL(t *testing.T) {
	cases := []struct{ remote, want string }{
		{"git@github.com:GregorMcC/loam.git", "https://github.com/GregorMcC/loam"},
		{"git@github.com:GregorMcC/loam", "https://github.com/GregorMcC/loam"},
		{"ssh://git@github.com/GregorMcC/loam.git", "https://github.com/GregorMcC/loam"},
		{"ssh://git@gitlab.example.com:2222/team/app.git", "https://gitlab.example.com/team/app"},
		{"https://github.com/GregorMcC/loam.git", "https://github.com/GregorMcC/loam"},
		{"https://github.com/GregorMcC/loam/", "https://github.com/GregorMcC/loam"},
		// A token in the remote never reaches the link.
		{"https://x-access-token:secret@github.com/GregorMcC/loam.git", "https://github.com/GregorMcC/loam"},
		{"http://git.example.com:8080/team/app.git", "http://git.example.com:8080/team/app"},
		{"  git@bitbucket.org:team/app.git\n", "https://bitbucket.org/team/app"},
		// Local remotes have no web page.
		{"/srv/git/app.git", ""},
		{"../app.git", ""},
		{"file:///srv/git/app.git", ""},
		{"", ""},
		{"https://github.com/", ""},
	}
	for _, c := range cases {
		got, ok := WebURL(c.remote)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("WebURL(%q) = %q, %v; want %q", c.remote, got, ok, c.want)
		}
	}
}

func TestLabel(t *testing.T) {
	cases := []struct{ url, want string }{
		{"https://github.com/GregorMcC/loam", "loam on GitHub"},
		{"https://gitlab.com/team/app", "app on GitLab"},
		{"https://bitbucket.org/team/app", "app on Bitbucket"},
		{"https://git.example.com/team/app", "app on git.example.com"},
	}
	for _, c := range cases {
		if got := Label(c.url); got != c.want {
			t.Errorf("Label(%q) = %q; want %q", c.url, got, c.want)
		}
	}
}

// gitRepo makes a git repo with the given remotes, in order. Git runs with no global config.
func gitRepo(t *testing.T, remotes ...[2]string) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	for _, r := range remotes {
		run("remote", "add", r[0], r[1])
	}
	return dir
}

func TestFindPrefersOriginElseTheFirstRemote(t *testing.T) {
	both := gitRepo(t, [2]string{"upstream", "git@github.com:other/app.git"}, [2]string{"origin", "git@github.com:me/app.git"})
	if got, ok := Find(both); !ok || got != "https://github.com/me/app" {
		t.Fatalf("Find with origin = %q, %v", got, ok)
	}
	upstream := gitRepo(t, [2]string{"upstream", "git@github.com:other/app.git"})
	if got, ok := Find(upstream); !ok || got != "https://github.com/other/app" {
		t.Fatalf("Find with upstream only = %q, %v", got, ok)
	}
	if got, ok := Find(gitRepo(t)); ok {
		t.Fatalf("Find with no remote = %q", got)
	}
	if got, ok := Find(t.TempDir()); ok {
		t.Fatalf("Find in a plain folder = %q", got)
	}
}

func TestLinkEditSkipsALinkThePlotHas(t *testing.T) {
	repo := gitRepo(t, [2]string{"origin", "git@github.com:me/app.git"})
	e, ok := LinkEdit(store.Plot{}, repo)
	if !ok || e.Op != store.OpAddLink || *e.Label != "app on GitHub" || *e.Target != "https://github.com/me/app" {
		t.Fatalf("LinkEdit = %+v, %v", e, ok)
	}
	has := store.Plot{Links: []store.Link{{Label: "Code", Target: "https://github.com/me/app/"}}}
	if _, ok := LinkEdit(has, repo); ok {
		t.Fatal("LinkEdit added a link the plot has")
	}
}

func TestAddLinksForANewPlot(t *testing.T) {
	app := gitRepo(t, [2]string{"origin", "git@github.com:me/app.git"})
	same := gitRepo(t, [2]string{"origin", "https://github.com/me/app.git"})
	plain := t.TempDir()
	got := AddLinks([]store.LinkInput{{Label: "Spec", Target: "/notes/spec.md"}},
		[]store.RepoInput{{Path: app}, {Path: same}, {Path: plain}})
	want := []store.LinkInput{{Label: "Spec", Target: "/notes/spec.md"}, {Label: "app on GitHub", Target: "https://github.com/me/app"}}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("AddLinks = %+v", got)
	}
}
