package sandbox

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

// maxLinks is how many links walkPath follows in one path. The system gives
// up before this count, so a path with more opens nothing now, but Loam cannot
// say what it would open later.
const maxLinks = 64

// WritePathOf returns the write path that holds path, or "" when none does.
// also are folders that the sandbox lets the run write besides the rules, such
// as the temporary folders. A path that a denied rule covers still counts: a
// caller that uses this answer must not depend on a deny rule.
//
// It walks path as the system does, and counts each name on the way, not only
// the last one. A name in a write path can be a link that the run changes, or
// a folder that it moves, so a path through a write path is held by it even
// when the path ends outside. The path need not exist: the run can make what
// is missing. It compares with the rule of the volume of a Mac, without regard
// to case and Unicode normalization. On a volume that tells them apart, two
// such names are two files, and the answer is on the safe side.
//
// It returns an error when it cannot say where path goes.
func (r Rules) WritePathOf(path string, also ...string) (string, error) {
	names, err := walkPath(path)
	if err != nil {
		return "", err
	}
	type folder struct{ name, key string }
	var writes []folder
	for _, w := range append(append([]string(nil), r.Write...), also...) {
		w = filepath.Clean(w)
		writes = append(writes, folder{w, volumeKey(w)})
		if inner, err := walkPath(w); err == nil && len(inner) > 0 {
			writes = append(writes, folder{w, volumeKey(inner[len(inner)-1])})
		}
	}
	for _, n := range names {
		key := volumeKey(n)
		for _, w := range writes {
			if within(key, w.key) {
				return w.name, nil
			}
		}
	}
	return "", nil
}

// Resolve returns the real path that the system reaches for the absolute path,
// as walkPath finds it. Unlike [Real], it follows a link before a "..", also in
// a path that does not exist.
func Resolve(path string) (string, error) {
	names, err := walkPath(path)
	if err != nil {
		return "", err
	}
	return names[len(names)-1], nil
}

// walkPath returns each name that the system passes through to open the
// absolute path, by its real path, and last the path that it ends at. It reads
// a link where it finds one, also a link to a file that does not exist, which
// filepath.EvalSymlinks does not follow. A ".." goes up from where the walk is,
// so from the target of a link. Below a name that does not exist, it takes the
// rest by the text.
func walkPath(path string) ([]string, error) {
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("the path %q is not absolute", path)
	}
	var names []string
	at := string(filepath.Separator)
	rest := elements(path)
	for links := 0; len(rest) > 0; {
		e := rest[0]
		rest = rest[1:]
		switch e {
		case "", ".":
			continue
		case "..":
			at = filepath.Dir(at)
			continue
		}
		next := filepath.Join(at, e)
		names = append(names, next)
		fi, err := os.Lstat(next)
		switch {
		case errors.Is(err, fs.ErrNotExist), errors.Is(err, syscall.ENOTDIR):
			at = next
		case err != nil:
			return nil, err
		case fi.Mode()&os.ModeSymlink == 0:
			at = next
		default:
			if links++; links > maxLinks {
				return nil, fmt.Errorf("the path %q follows more than %d links", path, maxLinks)
			}
			target, err := os.Readlink(next)
			if err != nil {
				return nil, err
			}
			if filepath.IsAbs(target) {
				at = string(filepath.Separator)
			}
			rest = append(elements(target), rest...)
		}
	}
	return append(names, at), nil
}

func elements(path string) []string {
	return strings.Split(path, string(filepath.Separator))
}

// volumeKey returns the name that the volume of a Mac compares: the case folded
// and the Unicode form decomposed. Two names with one key can be one file.
func volumeKey(path string) string {
	return norm.NFD.String(cases.Fold().String(norm.NFD.String(path)))
}
