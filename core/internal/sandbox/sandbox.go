// Package sandbox builds the rules of the sandbox that a run works in. The
// rules deny home, then allow the folders that the work needs: the folder of
// the run, its git folder, the repos and the local links of the plot, and the
// caches of each stack that the repo files name. Loam writes the rules as the
// sandbox block of the run settings and as the profile of the gate.
package sandbox

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
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
	// GitConfig are the config files that git reads in Folder. The caller
	// adds the files that they include with AllowRead, after For, because it
	// must know which files the run can write.
	GitConfig []string
	// NoWrite are folders that the run must not write, even when Claude Code
	// allows them, as it allows each --add-dir folder. A denied folder wins
	// over an allowed folder inside it, so it must not hold Folder or GitDir.
	NoWrite []string
	// Machine and Plot are the paths and hosts that the user added for every
	// plot and for this plot. For checks them again with the same rules as the
	// settings, and leaves out a value that fails.
	Machine, Plot Extra
	// Protected are folders that no setting may open, besides ~/.loam and
	// ~/.claude: the Loam home when LOAM_HOME moves it.
	Protected []string
	// Getenv reads the environment, for the cache paths that a user moved.
	Getenv func(string) string
}

// Rules are the paths below home that a run can read and write, and the hosts
// that it can reach. Paths are absolute and real: the sandbox matches real
// paths, and on macOS /var is a link to /private/var. DenyWrite wins over
// Write, for a path inside a written folder too.
type Rules struct {
	Home        string
	Read, Write []string
	DenyWrite   []string
	Hosts       []string
	// Notes tell the session what its stacks need in the sandbox.
	Notes []string
}

// A preset is what one stack needs: the files that name it, the caches that
// it reads and writes, the toolchain folders that it only reads, and the
// hosts that it fetches from. Paths are relative to home.
type preset struct {
	files     []string
	caches    func(home string, getenv func(string) string) []string
	toolchain []string
	hosts     []string
	// note tells the session what the stack needs in the sandbox.
	note string
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
		// govulncheck reads vuln.go.dev.
		hosts: []string{"proxy.golang.org", "sum.golang.org", "vuln.go.dev"},
	},
	{
		files:  []string{"Package.swift"},
		caches: below("Library/Caches/org.swift.swiftpm", "Library/org.swift.swiftpm"),
		// SwiftPM runs the manifest in a sandbox of its own, and a sandbox
		// cannot start inside another one.
		note: "Pass --disable-sandbox to swift build, swift test, and swift package: SwiftPM's own sandbox cannot start inside this one.",
	},
	{
		// Loam itself: scripts/build-ghosttykit.sh links app/vendor to this
		// cache, and the gate builds the terminal and the driver from it. Read
		// only, so a run cannot change the GhosttyKit that an install builds
		// with. Not the rest of ~/Library/Caches/Loam, which holds Zig and the
		// ghostty source.
		files:     []string{"ghostty.pin"},
		caches:    below(),
		toolchain: []string{"Library/Caches/Loam/ghosttykit"},
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

// goCaches are the module cache, the checksum database cache, the build
// cache, and the telemetry folder of Go, and the cache of golangci-lint.
// GOMODCACHE, GOPATH, and GOCACHE move the first three. Go keeps the checksum
// database cache below the first GOPATH entry, also when GOMODCACHE moves the
// module cache.
func goCaches(home string, getenv func(string) string) []string {
	gopath, _, _ := strings.Cut(getenv("GOPATH"), string(os.PathListSeparator))
	if gopath == "" {
		gopath = filepath.Join(home, "go")
	}
	mod := getenv("GOMODCACHE")
	if mod == "" {
		mod = filepath.Join(gopath, "pkg", "mod")
	}
	build := getenv("GOCACHE")
	if build == "" || build == "off" {
		build = filepath.Join(home, "Library", "Caches", "go-build")
	}
	return []string{
		mod, filepath.Join(gopath, "pkg", "sumdb"), build,
		filepath.Join(home, "Library", "Application Support", "go", "telemetry"),
		filepath.Join(home, "Library", "Caches", "golangci-lint"),
	}
}

// GoModCache returns the module cache of Go, as [goCaches] names it.
func GoModCache(home string, getenv func(string) string) string {
	return goCaches(home, getenv)[0]
}

// gitConfig are the git config files that git reads in each command. They
// are files, not the folder: ~/.config/git/credentials holds a token.
func gitConfig(home string) []string {
	return []string{
		filepath.Join(home, ".gitconfig"),
		filepath.Join(home, ".config", "git", "config"),
		filepath.Join(home, ".config", "git", "ignore"),
		filepath.Join(home, ".config", "git", "attributes"),
	}
}

// For returns the rules of a run. It leaves out a repo or a link that would
// open home: home itself, a folder above it, or a credential folder. It
// returns an error when the home folder is not absolute, or when the folder of
// the run is such a path, because the rules would then deny nothing.
func For(in Input) (Rules, error) {
	if !filepath.IsAbs(in.Home) {
		return Rules{}, errors.New("the sandbox needs the home folder, and it is not set")
	}
	home := Real(in.Home)
	if opens(home, Real(in.Folder)) {
		return Rules{}, fmt.Errorf("the sandbox cannot hold a run in %s: it is the home folder, a folder above it, or a credential folder", in.Folder)
	}
	r := Rules{Home: home}
	var read, write, deny, hosts, notes set
	allow := func(s *set, paths ...string) {
		for _, p := range paths {
			if p = Real(p); p != "" && !opens(home, p) {
				s.add(p)
			}
		}
	}
	allow(&read, in.Folder, in.GitDir)
	allow(&read, in.Repos...)
	allow(&read, in.Links...)
	allow(&read, gitConfig(in.Home)...)
	allow(&read, in.GitConfig...)
	allow(&write, in.Folder, in.GitDir)
	for _, p := range presets {
		if !anyRepoHas(in.Repos, p.files) {
			continue
		}
		caches := p.caches(in.Home, in.Getenv)
		allow(&read, caches...)
		allow(&read, under(in.Home, p.toolchain)...)
		allow(&write, caches...)
		hosts.add(p.hosts...)
		notes.add(p.note)
	}
	addExtra(in.Home, in.Protected, in.Machine, &read, &write, &hosts)
	addExtra(in.Home, in.Protected, in.Plot, &read, &write, &hosts)
	for _, p := range in.NoWrite {
		deny.add(Real(p))
	}
	if dotgit := filepath.Join(Real(in.Folder), ".git"); isFile(dotgit) {
		// The .git file of a worktree names its git folder. Pointed at a
		// folder of the run, it would make the next git command of Loam run
		// a hook or a config command of the run outside the sandbox.
		deny.add(dotgit)
	}
	if git := Real(in.GitDir); git != "" {
		// A hook or a config that the run writes would run outside the
		// sandbox, in the next git command of Loam or of the user.
		deny.add(filepath.Join(git, "hooks"), filepath.Join(git, "config"))
	}
	r.Read, r.Write, r.DenyWrite, r.Hosts, r.Notes = read.list, write.list, deny.list, hosts.list, notes.list
	return r, nil
}

// opens reports whether allowing path would open what the sandbox denies:
// the root, home, a folder above home, a credential path, a path in one, or a
// folder that holds one. It ignores case, because macOS folders are not case
// sensitive by default.
func opens(home, path string) bool {
	if path == "" {
		return false
	}
	home, path = strings.ToLower(home), strings.ToLower(path)
	if path == string(filepath.Separator) || within(home, path) {
		return true
	}
	for _, c := range credentials {
		c = filepath.Join(home, strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(c, "~/"), "/**")))
		if within(path, c) || within(c, path) {
			return true
		}
	}
	return false
}

// Writable reports whether the run can write path: it is in a write path of
// the rules, or in one of also, and in no path that the rules deny. also are
// folders that the sandbox lets the run write besides the rules, such as the
// temporary folders. It checks the path as given and with its symlinks
// resolved, because the run can point a link in a write path at another file.
// The compare ignores case, as macOS folders do by default. On a volume that
// does not, the check can take a file for writable when it is not, which is
// the safe side.
func (r Rules) Writable(path string, also ...string) bool {
	in := func(p string, dirs []string) bool {
		for _, d := range dirs {
			if within(p, strings.ToLower(d)) {
				return true
			}
		}
		return false
	}
	write := slices.Clone(r.Write)
	for _, d := range also {
		write = append(write, filepath.Clean(d), Real(d))
	}
	for _, p := range []string{filepath.Clean(path), Real(path)} {
		if p = strings.ToLower(p); in(p, write) && !in(p, r.DenyWrite) {
			return true
		}
	}
	return false
}

// Refuses reports whether the rules never let the run read path, because it
// would open home, as For checks for each path that it allows.
func (r Rules) Refuses(path string) bool {
	return opens(r.Home, Real(path))
}

// AllowRead adds read paths to the rules with the check of For: it leaves
// out a path that the rules refuse. It returns the paths that it left out. It
// adds a path once. Two names of a path that differ in case stay two paths:
// on a volume that does not ignore case, they are two files.
func (r *Rules) AllowRead(paths ...string) (left []string) {
	for _, p := range paths {
		p = Real(p)
		switch {
		case p == "":
		case r.Refuses(p):
			left = append(left, p)
		case !slices.Contains(r.Read, p):
			r.Read = append(r.Read, p)
		}
	}
	return left
}

// within reports whether path is dir or a path inside it.
func within(path, dir string) bool {
	return path == dir || strings.HasPrefix(path, dir+string(filepath.Separator))
}

// Real resolves the symlinks of path. A path that does not exist yet keeps
// its name below its resolved parent.
func Real(path string) string {
	if path == "" {
		return ""
	}
	if r, err := filepath.EvalSymlinks(path); err == nil {
		return r
	}
	if r, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		return filepath.Join(r, filepath.Base(path))
	}
	return filepath.Clean(path)
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

func isFile(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && !info.IsDir()
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
