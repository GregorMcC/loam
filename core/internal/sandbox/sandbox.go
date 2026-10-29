// Package sandbox builds the rules of the sandbox that a run works in. The
// rules deny home, then allow the folders that the work needs: the folder of
// the run, its git folder, the repos and the local links of the plot, and the
// caches of each stack that the repo files name. Loam writes the rules as the
// sandbox block of the run settings and as the profile of the gate.
package sandbox

import (
	"os"
	"path/filepath"
	"strings"
)

// Input is what the rules of a run come from.
type Input struct {
	// Home is the home folder. The sandbox denies it, except for the paths
	// that the rules allow.
	Home string
	// Folder is where the run works. GitDir is its git folder, which for a
	// worktree is the git folder of the main checkout.
	Folder, GitDir string
	// Repos are the repo paths of the plot. Links are its local links.
	Repos, Links []string
	// NoWrite are folders that the run must not write, even when Claude Code
	// allows them, as it allows each --add-dir folder. A denied folder wins
	// over an allowed folder inside it, so it must not hold Folder or GitDir.
	NoWrite []string
	// Getenv reads the environment, for the cache paths that a user moved.
	Getenv func(string) string
}

// Rules are the paths below home that a run can read and write, and the hosts
// that it can reach. Paths are absolute.
type Rules struct {
	Home        string
	Read, Write []string
	DenyWrite   []string
	Hosts       []string
}

// A preset is what one stack needs: the files that name it, the caches that
// it reads and writes, the toolchain folders that it only reads, and the
// hosts that it fetches from. Paths are relative to home.
type preset struct {
	files     []string
	caches    func(home string, getenv func(string) string) []string
	toolchain []string
	hosts     []string
}

// below returns a caches func for fixed paths below home.
func below(paths ...string) func(string, func(string) string) []string {
	return func(home string, _ func(string) string) []string { return under(home, paths) }
}

func under(home string, paths []string) []string {
	out := make([]string, len(paths))
	for i, p := range paths {
		out[i] = filepath.Join(home, p)
	}
	return out
}

var presets = []preset{
	{
		files:  []string{"go.mod"},
		caches: goCaches,
		hosts:  []string{"proxy.golang.org", "sum.golang.org"},
	},
	{
		files:  []string{"Package.swift"},
		caches: below("Library/Caches/org.swift.swiftpm", "Library/org.swift.swiftpm"),
	},
	{
		files:  []string{"package.json"},
		caches: below(".npm"),
		hosts:  []string{"registry.npmjs.org"},
	},
	{
		// Not ~/.cargo: ~/.cargo/credentials.toml holds the registry token.
		files:     []string{"Cargo.toml"},
		caches:    below(".cargo/registry", ".cargo/git"),
		toolchain: []string{".cargo/bin", ".rustup"},
		hosts:     []string{"crates.io", "index.crates.io", "static.crates.io"},
	},
	{
		files:  []string{"pyproject.toml", "requirements.txt"},
		caches: below("Library/Caches/pip"),
		hosts:  []string{"pypi.org", "files.pythonhosted.org"},
	},
}

// goCaches are the module cache, the build cache, and the telemetry folder of
// Go. GOMODCACHE, GOPATH, and GOCACHE move the first two.
func goCaches(home string, getenv func(string) string) []string {
	mod := getenv("GOMODCACHE")
	if mod == "" {
		gopath, _, _ := strings.Cut(getenv("GOPATH"), string(os.PathListSeparator))
		if gopath == "" {
			gopath = filepath.Join(home, "go")
		}
		mod = filepath.Join(gopath, "pkg", "mod")
	}
	build := getenv("GOCACHE")
	if build == "" || build == "off" {
		build = filepath.Join(home, "Library", "Caches", "go-build")
	}
	return []string{mod, build, filepath.Join(home, "Library", "Application Support", "go", "telemetry")}
}

// gitConfig are the git config files that git reads in each command.
func gitConfig(home string) []string {
	return []string{filepath.Join(home, ".gitconfig"), filepath.Join(home, ".config", "git")}
}

// For returns the rules of a run.
func For(in Input) Rules {
	r := Rules{Home: in.Home}
	var read, write, hosts set
	read.add(in.Folder, in.GitDir)
	read.add(in.Repos...)
	read.add(in.Links...)
	read.add(gitConfig(in.Home)...)
	write.add(in.Folder, in.GitDir)
	for _, p := range presets {
		if !anyRepoHas(in.Repos, p.files) {
			continue
		}
		caches := p.caches(in.Home, in.Getenv)
		read.add(caches...)
		read.add(under(in.Home, p.toolchain)...)
		write.add(caches...)
		hosts.add(p.hosts...)
	}
	var deny set
	deny.add(in.NoWrite...)
	r.Read, r.Write, r.DenyWrite, r.Hosts = read.list, write.list, deny.list, hosts.list
	return r
}

// anyRepoHas reports whether a repo holds one of the files at its root or
// one folder down, as a repo with core/go.mod and app/Package.swift does.
func anyRepoHas(repos, files []string) bool {
	for _, repo := range repos {
		for _, f := range files {
			if exists(filepath.Join(repo, f)) {
				return true
			}
			if m, _ := filepath.Glob(filepath.Join(globEscape(repo), "*", f)); len(m) > 0 {
				return true
			}
		}
	}
	return false
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// globEscape quotes the glob characters of a path.
func globEscape(path string) string {
	var b strings.Builder
	for _, c := range path {
		if strings.ContainsRune(`*?[\`, c) {
			b.WriteRune('\\')
		}
		b.WriteRune(c)
	}
	return b.String()
}

// set is a list with no repeats and no empty items, in the order of adding.
type set struct {
	list []string
	seen map[string]bool
}

func (s *set) add(items ...string) {
	if s.seen == nil {
		s.seen = map[string]bool{}
	}
	for _, it := range items {
		if it != "" && !s.seen[it] {
			s.seen[it] = true
			s.list = append(s.list, it)
		}
	}
}
