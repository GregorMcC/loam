package sandbox

import (
	"os"
	"path/filepath"
	"slices"
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

// TAS-175: a run reads its folder, the repos and the local links of its plot,
// and the caches of the stacks that the repo files name. The rest of home
// stays denied. It writes only its folder, the git folder, and the caches.
func TestForAGoRepoASwiftRepoAndALink(t *testing.T) {
	dir := t.TempDir()
	api := filepath.Join(dir, "api")
	app := filepath.Join(dir, "app")
	mkfile(t, filepath.Join(api, "go.mod"))
	mkfile(t, filepath.Join(app, "app", "Package.swift"))
	work := filepath.Join(dir, "worktrees", "api-fix")
	git := filepath.Join(api, ".git")
	spec := filepath.Join(dir, "notes", "spec.md")

	got := For(Input{
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
			"/h/.gitconfig", "/h/.config/git",
			"/h/go/pkg/mod", "/h/Library/Caches/go-build", "/h/Library/Application Support/go/telemetry",
			"/h/Library/Caches/org.swift.swiftpm", "/h/Library/org.swift.swiftpm",
		}},
		{"Write", got.Write, []string{
			work, git,
			"/h/go/pkg/mod", "/h/Library/Caches/go-build", "/h/Library/Application Support/go/telemetry",
			"/h/Library/Caches/org.swift.swiftpm", "/h/Library/org.swift.swiftpm",
		}},
		{"Hosts", got.Hosts, []string{"proxy.golang.org", "sum.golang.org"}},
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
			repo := t.TempDir()
			mkfile(t, filepath.Join(repo, c.file))
			got := For(Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: noEnv})
			base := []string{repo, "/h/.gitconfig", "/h/.config/git"}
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
	repo := t.TempDir()
	got := For(Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: noEnv})
	if len(got.Hosts) != 0 || !slices.Equal(got.Write, []string{repo}) {
		t.Errorf("got Write %q and Hosts %q, want only the repo and no hosts", got.Write, got.Hosts)
	}
}

// A user who moved the Go caches gets the moved paths.
func TestForGoHonoursTheCacheEnv(t *testing.T) {
	repo := t.TempDir()
	mkfile(t, filepath.Join(repo, "go.mod"))
	env := map[string]string{"GOPATH": "/gp:/other", "GOCACHE": "/cache/go"}
	got := For(Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: func(k string) string { return env[k] }})
	if !slices.Contains(got.Write, "/gp/pkg/mod") || !slices.Contains(got.Write, "/cache/go") {
		t.Errorf("Write = %q, want /gp/pkg/mod and /cache/go", got.Write)
	}
	env["GOMODCACHE"] = "/mods"
	got = For(Input{Home: "/h", Folder: repo, Repos: []string{repo}, Getenv: func(k string) string { return env[k] }})
	if !slices.Contains(got.Write, "/mods") || slices.Contains(got.Write, "/gp/pkg/mod") {
		t.Errorf("Write = %q, want /mods in place of /gp/pkg/mod", got.Write)
	}
}
