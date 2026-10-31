package sandbox

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func mkfile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func noEnv(string) string { return "" }

// realTemp returns a temp folder by its real path, as the rules give it.
func realTemp(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func mustFor(t *testing.T, in Input) Rules {
	t.Helper()
	r, err := For(in)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// TAS-175: a run reads its folder, the repos and the local links of its plot,
// and the caches of the stacks that the repo files name. The rest of home
// stays denied. It writes only its folder, the git folder, and the caches.
func TestForAGoRepoASwiftRepoAndALink(t *testing.T) {
	dir := realTemp(t)
	api := filepath.Join(dir, "api")
	app := filepath.Join(dir, "app")
	mkfile(t, filepath.Join(api, "go.mod"))
	mkfile(t, filepath.Join(app, "app", "Package.swift"))
	work := filepath.Join(dir, "worktrees", "api-fix")
	git := filepath.Join(api, ".git")
	spec := filepath.Join(dir, "notes", "spec.md")

	got := mustFor(t, Input{
		Home:   "/h",
		Folder: work,
		GitDir: git,
		Repos:  []string{api, app},
		Links:  []string{spec},
		Getenv: noEnv,
	})

	cases := []struct {
		name      string
		got, want []string
	}{
		{"Read", got.Read, []string{
			work, git, api, app, spec,
			"/h/.gitconfig", "/h/.config/git/config", "/h/.config/git/ignore", "/h/.config/git/attributes",
			"/h/go/pkg/mod", "/h/go/pkg/sumdb", "/h/Library/Caches/go-build", "/h/Library/Application Support/go/telemetry", "/h/Library/Caches/golangci-lint",
			"/h/Library/Caches/org.swift.swiftpm", "/h/Library/org.swift.swiftpm",
		}},
		{"Write", got.Write, []string{
			work, git,
			"/h/go/pkg/mod", "/h/go/pkg/sumdb", "/h/Library/Caches/go-build", "/h/Library/Application Support/go/telemetry", "/h/Library/Caches/golangci-lint",
			"/h/Library/Caches/org.swift.swiftpm", "/h/Library/org.swift.swiftpm",
		}},
		{"Hosts", got.Hosts, []string{"proxy.golang.org", "sum.golang.org", "vuln.go.dev"}},
		{"DenyWrite", got.DenyWrite, []string{filepath.Join(git, "hooks"), filepath.Join(git, "config")}},
	}
	for _, c := range cases {
		if !slices.Equal(c.got, c.want) {
			t.Errorf("%s =\n  %q\nwant\n  %q", c.name, c.got, c.want)
		}
	}
	if got.Home != "/h" {
		t.Errorf("Home = %q, want /h", got.Home)
	}
}

// Each stack file adds its caches and hosts. A toolchain folder is read only.
// Rust never gets ~/.cargo, because ~/.cargo/credentials.toml holds a token.
func TestForPicksThePresetOfEachStackFile(t *testing.T) {
	for _, c := range []struct {
		file               string
		read, write, hosts []string
	}{
		{
			file:  "package.json",
			read:  []string{"/h/.npm"},
			write: []string{"/h/.npm"},
			hosts: []string{"registry.npmjs.org"},
		},
		{
			file:  "Cargo.toml",
			read:  []string{"/h/.cargo/registry", "/h/.cargo/git", "/h/.cargo/bin", "/h/.rustup"},
			write: []string{"/h/.cargo/registry", "/h/.cargo/git"},
			hosts: []string{"crates.io", "index.crates.io", "static.crates.io"},
		},
		{
			file:  "pyproject.toml",
			read:  []string{"/h/Library/Caches/pip"},
			write: []string{"/h/Library/Caches/pip"},
			hosts: []string{"pypi.org", "files.pythonhosted.org"},
		},
		{
			file:  "requirements.txt",
			read:  []string{"/h/Library/Caches/pip"},
			write: []string{"/h/Library/Caches/pip"},
			hosts: []string{"pypi.org", "files.pythonhosted.org"},
		},
	} {
		t.Run(c.file, func(t *testing.T) {
			repo := realTemp(t)
			mkfile(t, filepath.Join(repo, c.file))
			got := mustFor(t, Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: noEnv})
			base := []string{repo, "/h/.gitconfig", "/h/.config/git/config", "/h/.config/git/ignore", "/h/.config/git/attributes"}
			if want := append(base, c.read...); !slices.Equal(got.Read, want) {
				t.Errorf("Read = %q, want %q", got.Read, want)
			}
			if want := append([]string{repo}, c.write...); !slices.Equal(got.Write, want) {
				t.Errorf("Write = %q, want %q", got.Write, want)
			}
			if !slices.Equal(got.Hosts, c.hosts) {
				t.Errorf("Hosts = %q, want %q", got.Hosts, c.hosts)
			}
		})
	}
}

// A repo with no stack file adds nothing past its own paths.
func TestForARepoWithNoStackFile(t *testing.T) {
	repo := realTemp(t)
	got := mustFor(t, Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: noEnv})
	if len(got.Hosts) != 0 || !slices.Equal(got.Write, []string{repo}) {
		t.Errorf("got Write %q and Hosts %q, want only the repo and no hosts", got.Write, got.Hosts)
	}
}

// A user who moved the Go caches gets the moved paths.
func TestForGoHonoursTheCacheEnv(t *testing.T) {
	repo := realTemp(t)
	mkfile(t, filepath.Join(repo, "go.mod"))
	env := map[string]string{"GOPATH": "/gp:/other", "GOCACHE": "/cache/go"}
	got := mustFor(t, Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: func(k string) string { return env[k] }})
	if !slices.Contains(got.Write, "/gp/pkg/mod") || !slices.Contains(got.Write, "/gp/pkg/sumdb") || !slices.Contains(got.Write, "/cache/go") {
		t.Errorf("Write = %q, want /gp/pkg/mod, /gp/pkg/sumdb, and /cache/go", got.Write)
	}
	// GOMODCACHE moves the module cache, and not the checksum database cache.
	env["GOMODCACHE"] = "/mods"
	got = mustFor(t, Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: func(k string) string { return env[k] }})
	if !slices.Contains(got.Write, "/mods") || slices.Contains(got.Write, "/gp/pkg/mod") || !slices.Contains(got.Write, "/gp/pkg/sumdb") {
		t.Errorf("Write = %q, want /mods in place of /gp/pkg/mod, and /gp/pkg/sumdb", got.Write)
	}
}

// A repo or a link that would open home is left out: home, a folder above it,
// the root, or a credential folder. The rest stays.
func TestForLeavesOutPathsThatOpenHome(t *testing.T) {
	repo := realTemp(t)
	home := realTemp(t)
	got := mustFor(t, Input{
		Home:   home,
		Folder: repo,
		Repos:  []string{repo, home},
		Links: []string{
			home, filepath.Dir(home), "/",
			filepath.Join(home, ".ssh"), filepath.Join(home, ".ssh", "config"), filepath.Join(home, ".config", "gh"),
			// These hold credential folders: ~/.config/gh, ~/Library/Keychains.
			filepath.Join(home, ".config"), filepath.Join(home, "Library"),
			filepath.Join(home, ".config", "git", "credentials"),
			filepath.Join(home, "notes"),
		},
		Getenv: noEnv,
	})
	want := []string{repo, filepath.Join(home, "notes"), filepath.Join(home, ".gitconfig"),
		filepath.Join(home, ".config", "git", "config"), filepath.Join(home, ".config", "git", "ignore"), filepath.Join(home, ".config", "git", "attributes")}
	if !slices.Equal(got.Read, want) {
		t.Errorf("Read =\n  %q\nwant\n  %q", got.Read, want)
	}
}

// A run in home, or with no home folder, gets no rules: they would deny
// nothing.
func TestForRefusesARunThatTheRulesCannotHold(t *testing.T) {
	home := realTemp(t)
	for _, in := range []Input{
		{Home: "", Folder: "/w"},
		{Home: home, Folder: home},
		{Home: home, Folder: filepath.Dir(home)},
		{Home: home, Folder: filepath.Join(home, ".ssh", "x")},
	} {
		in.Getenv = noEnv
		if _, err := For(in); err == nil {
			t.Errorf("For(%+v) gave no error", in)
		}
	}
}

// A cache that the user moved behind a symlink is allowed by its real path.
func TestForResolvesTheCachePaths(t *testing.T) {
	repo := realTemp(t)
	mkfile(t, filepath.Join(repo, "go.mod"))
	real := realTemp(t)
	link := filepath.Join(realTemp(t), "mods")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	got := mustFor(t, Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: func(k string) string {
		if k == "GOMODCACHE" {
			return link
		}
		return ""
	}})
	if !slices.Contains(got.Write, real) || slices.Contains(got.Write, link) {
		t.Errorf("Write = %q, want %s in place of %s", got.Write, real, link)
	}
}

// SwiftPM runs its manifest in a sandbox of its own, which cannot start inside
// the run's sandbox. So the prompt of a run with a Swift repo asks for
// --disable-sandbox. A run with no such stack gets only the note that every
// run gets.
func TestPromptNamesWhatTheSandboxNeeds(t *testing.T) {
	swift := realTemp(t)
	mkfile(t, filepath.Join(swift, "Package.swift"))
	got := mustFor(t, Input{Home: "/h", Folder: swift, Repos: []string{swift}, Getenv: noEnv}).Prompt()
	if !strings.Contains(got, "--disable-sandbox") {
		t.Errorf("Prompt = %q, want --disable-sandbox", got)
	}
	// Every run hears not to work around a denial.
	if !strings.Contains(got, "Do not work around it") {
		t.Errorf("Prompt = %q, want the note of every run", got)
	}
	plain := realTemp(t)
	got = mustFor(t, Input{Home: "/h", Folder: plain, Repos: []string{plain}, Getenv: noEnv}).Prompt()
	if strings.Contains(got, "--disable-sandbox") || !strings.Contains(got, "Do not work around it") {
		t.Errorf("Prompt = %q, want the note of every run only", got)
	}
}

// macOS folders are not case sensitive, so a link to ~/.SSH is still the
// credential folder.
func TestForComparesPathsWithNoCase(t *testing.T) {
	repo := realTemp(t)
	home := realTemp(t)
	got := mustFor(t, Input{Home: home, Folder: repo, Links: []string{
		filepath.Join(home, ".SSH"), filepath.Join(strings.ToUpper(home), ".aws", "x"), strings.ToUpper(home),
	}, Getenv: noEnv})
	if len(got.Read) != 5 {
		t.Errorf("Read = %q, want only the folder and the git config", got.Read)
	}
}

// The .git file of a worktree names its git folder. A run that points it at a
// folder of its own could make the git commands of Loam run a hook or a
// config command outside the sandbox. So the file is write-denied.
func TestForDeniesWritesToTheGitFileOfAWorktree(t *testing.T) {
	work := realTemp(t)
	mkfile(t, filepath.Join(work, ".git"))
	got := mustFor(t, Input{Home: "/h", Folder: work, Getenv: noEnv})
	if !slices.Contains(got.DenyWrite, filepath.Join(work, ".git")) {
		t.Errorf("DenyWrite = %q, want the .git file", got.DenyWrite)
	}
	repo := realTemp(t)
	if err := os.Mkdir(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	got = mustFor(t, Input{Home: "/h", Folder: repo, GitDir: filepath.Join(repo, ".git"), Getenv: noEnv})
	if slices.Contains(got.DenyWrite, filepath.Join(repo, ".git")) {
		t.Errorf("DenyWrite = %q denies the git folder of a checkout", got.DenyWrite)
	}
}

// Writable is true in a write path and false in a path that the rules deny
// inside it. It ignores case, as macOS folders do.
func TestRulesWritable(t *testing.T) {
	r := Rules{Write: []string{"/w/Repo"}, DenyWrite: []string{"/w/Repo/.git/config"}}
	for path, want := range map[string]bool{
		"/w/Repo/a.gitconfig":    true,
		"/w/repo/a.gitconfig":    true,
		"/w/Repo/.git/config":    false,
		"/w/Repository/a":        false,
		"/elsewhere/a.gitconfig": false,
	} {
		if got := r.Writable(path); got != want {
			t.Errorf("Writable(%s) = %v, want %v", path, got, want)
		}
	}
	// The run can point a link in a write path at another file.
	dir, other := realTemp(t), realTemp(t)
	link := filepath.Join(dir, "x.gitconfig")
	if err := os.Symlink(filepath.Join(other, "x.gitconfig"), link); err != nil {
		t.Fatal(err)
	}
	if !(Rules{Write: []string{dir}}).Writable(link) {
		t.Errorf("Writable(%s) = false for a link in a write path", link)
	}
	// A folder of also is a write path too.
	if !(Rules{}).Writable(filepath.Join(other, "y.gitconfig"), other) || (Rules{}).Writable(link) {
		t.Errorf("Writable does not take the folders of also as write paths")
	}
}

// AllowRead adds a path once, and leaves out and returns a path that opens
// home, as For does.
func TestRulesAllowRead(t *testing.T) {
	home := realTemp(t)
	inc := filepath.Join(home, "dotfiles", "work.gitconfig")
	cred := filepath.Join(home, ".ssh", "config")
	r := Rules{Home: home}
	left := r.AllowRead(inc, inc, cred)
	if !slices.Equal(r.Read, []string{inc}) || !slices.Equal(left, []string{cred}) {
		t.Errorf("Read = %q, left = %q, want %s and %s", r.Read, left, inc, cred)
	}
}

// The config files that git names are read paths, unless they open home.
func TestForAllowsTheGitConfigFiles(t *testing.T) {
	repo := realTemp(t)
	home := realTemp(t)
	inc := filepath.Join(home, "dotfiles", "git.inc")
	got := mustFor(t, Input{Home: home, Folder: repo, GitConfig: []string{inc, filepath.Join(home, ".ssh", "config")}, Getenv: noEnv})
	if !slices.Contains(got.Read, inc) || slices.Contains(got.Read, filepath.Join(home, ".ssh", "config")) {
		t.Errorf("Read = %q, want %s and no credential path", got.Read, inc)
	}
}

// TAS-216: the run reads and writes its private folder. The run can put a
// link in its place, so the rules leave out a link and do not follow it.
func TestForAllowsThePrivateFolderOfTheRun(t *testing.T) {
	work, parent := realTemp(t), realTemp(t)
	dir := filepath.Join(parent, "r1")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	got := mustFor(t, Input{Home: "/h", Folder: work, Private: dir, Getenv: noEnv})
	if !slices.Contains(got.Read, dir) || !slices.Contains(got.Write, dir) || !got.Writable(filepath.Join(dir, PrivateXcrunCache)) {
		t.Errorf("Read = %q, Write = %q, want the private folder %s", got.Read, got.Write, dir)
	}
	target := realTemp(t)
	link := filepath.Join(parent, "r2")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	got = mustFor(t, Input{Home: "/h", Folder: work, Private: link, Getenv: noEnv})
	if slices.Contains(got.Write, target) || slices.Contains(got.Write, link) {
		t.Errorf("Write = %q, want no link and no target of it", got.Write)
	}
}
