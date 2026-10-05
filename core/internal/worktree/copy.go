package worktree

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// worktreeInclude reads the patterns of .worktreeinclude in the repo. Each
// line is a path or a glob, relative to the repo root. A blank line, a line
// that starts with #, and a line that starts with ! are skipped.
func worktreeInclude(repo string) []string {
	f, err := os.Open(filepath.Join(repo, ".worktreeinclude"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "!") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// cleanPattern turns a pattern into a slash path inside the repo. It returns
// false for a pattern that leaves the repo.
func cleanPattern(p string) (string, bool) {
	p = strings.TrimPrefix(filepath.ToSlash(strings.TrimSpace(p)), "/")
	p = strings.TrimSuffix(p, "/")
	if p == "" || p == "." {
		return "", false
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return "", false
		}
	}
	p = path.Clean(p)
	if p == ".git" || strings.HasPrefix(p, ".git/") {
		return "", false
	}
	return p, true
}

// copyFiles copies the files that the patterns name from the repo into the
// worktree. It never overwrites a file, so a tracked file stays as git made it.
// It returns the copied files, and a warning for each problem.
func copyFiles(repo, dest string, patterns []string, quietMiss map[string]bool) (copied, warnings []string) {
	src := os.DirFS(repo)
	seen := map[string]bool{}
	for _, raw := range patterns {
		pat, ok := cleanPattern(raw)
		if !ok {
			warnings = append(warnings, fmt.Sprintf("Skipped %q: a file to copy must be inside the repo.", raw))
			continue
		}
		matches, err := fs.Glob(src, pat)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("Skipped %q: %v.", raw, err))
			continue
		}
		if len(matches) == 0 && !quietMiss[raw] {
			warnings = append(warnings, fmt.Sprintf("Did not copy %s: no such file in the repo.", raw))
		}
		for _, m := range matches {
			_ = fs.WalkDir(src, m, func(p string, d fs.DirEntry, err error) error {
				if err != nil {
					return nil
				}
				if d.IsDir() {
					if d.Name() == ".git" {
						return fs.SkipDir
					}
					return nil
				}
				if !d.Type().IsRegular() || seen[p] {
					return nil // skip links and devices, and files that two patterns name
				}
				seen[p] = true
				// A link anywhere in the path could read a file outside the
				// repo, or write one outside the worktree.
				if err := noLinks(repo, p); err != nil {
					warnings = append(warnings, fmt.Sprintf("Did not copy %s: %v.", p, err))
					return nil
				}
				if err := noLinks(dest, path.Dir(p)); err != nil {
					warnings = append(warnings, fmt.Sprintf("Did not copy %s: %v.", p, err))
					return nil
				}
				did, err := copyOne(filepath.Join(repo, filepath.FromSlash(p)), filepath.Join(dest, filepath.FromSlash(p)))
				switch {
				case err != nil:
					warnings = append(warnings, fmt.Sprintf("Did not copy %s: %v.", p, err))
				case did:
					copied = append(copied, p)
				}
				return nil
			})
		}
	}
	return copied, warnings
}

// noLinks returns an error when a part of the slash path rel under root is a
// symbolic link. Parts that do not exist yet are fine: copyOne makes them as
// folders.
func noLinks(root, rel string) error {
	cur := root
	for _, part := range strings.Split(rel, "/") {
		if part == "." || part == "" {
			continue
		}
		cur = filepath.Join(cur, part)
		fi, err := os.Lstat(cur)
		if err != nil {
			return nil
		}
		if fi.Mode()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symbolic link", cur)
		}
	}
	return nil
}

// copyOne copies one file with its mode. It does nothing when dst exists.
func copyOne(src, dst string) (bool, error) {
	if _, err := os.Lstat(dst); err == nil {
		return false, nil
	}
	in, err := os.Open(src)
	if err != nil {
		return false, err
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return false, err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, fi.Mode().Perm())
	if err != nil {
		return false, err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return false, err
	}
	return true, out.Close()
}
