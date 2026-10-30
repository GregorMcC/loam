package sandbox

import (
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
)

// Extra are the paths and hosts that the user adds to the sandbox, at the
// machine scope or the plot scope. A write path is also a read path. Only the
// user sets them: the CLI and the app, never a run session.
type Extra struct {
	Read, Write, Hosts []string
}

// CheckPath checks a path of the settings and returns it in its clean form.
// The path is absolute or starts with ~/. It must not open what the sandbox
// denies: home, a folder above it, the root, a credential folder, or a
// folder that holds one (such as ~/.config, which holds ~/.config/gh). It
// must not be, hold, or lie in a protected folder: ~/.loam, ~/.claude, and
// the folders in protected, such as a LOAM_HOME elsewhere. A run that wrote
// there could change its own settings. It must not hold a glob character, a
// quote, or a control character, because the sandbox could read them as a
// pattern or as the end of the path.
func CheckPath(home, path string, protected ...string) (string, error) {
	text, _, err := checkPath(home, path, protected)
	return text, err
}

// reserved are the folders below home that hold the settings of Loam and of
// Claude Code. A run that wrote there could widen its own sandbox.
var reserved = []string{".loam", ".claude"}

// checkPath returns the clean text of a path, with ~/ kept, and its absolute
// form.
func checkPath(home, path string, protected []string) (text, abs string, err error) {
	path = strings.TrimSpace(path)
	switch {
	case path == "~" || path == "~/":
		return "", "", fmt.Errorf("%q is the home folder", path)
	case strings.HasPrefix(path, "~/"):
		abs = filepath.Join(home, path[2:])
	case filepath.IsAbs(path):
		abs = filepath.Clean(path)
	default:
		return "", "", fmt.Errorf("%q is not an absolute path and does not start with ~/", path)
	}
	for _, c := range path {
		if unicode.IsControl(c) || strings.ContainsRune(`*?[]{}"\`, c) {
			return "", "", fmt.Errorf("%q holds the character %q, which a path of the sandbox cannot hold", path, c)
		}
	}
	// The firmlink /System/Volumes/Data/Users is the same folder as /Users.
	if rest, ok := strings.CutPrefix(abs, "/System/Volumes/Data/"); ok {
		abs = "/" + rest
	}
	if exposes(Real(home), Real(abs), protected) {
		return "", "", fmt.Errorf("%q is not allowed: it is the home folder, a folder above it, the root, a credential folder, a protected folder, or a folder that holds one", path)
	}
	if rel, ok := strings.CutPrefix(abs, filepath.Clean(home)+string(filepath.Separator)); ok {
		return "~/" + rel, abs, nil
	}
	return abs, abs, nil
}

// exposes reports whether allowing path would open what the sandbox denies:
// what [opens] names, or a folder that holds a credential path.
func exposes(home, path string, protected []string) bool {
	if opens(home, path) {
		return true
	}
	path = strings.ToLower(path)
	for _, r := range reserved {
		protected = append(protected, filepath.Join(home, r))
	}
	for _, p := range protected {
		if p = strings.ToLower(Real(p)); within(p, path) || within(path, p) {
			return true
		}
	}
	for _, c := range credentials {
		c = filepath.Join(strings.ToLower(home), strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(c, "~/"), "/**")))
		if within(c, path) {
			return true
		}
	}
	return false
}

// CheckHost checks a host of the settings and returns it in lower case. A host
// is a DNS name with at least two labels, or *. and such a name, so *.com is
// not a host. It is never *, a URL, a name with a port, localhost, or an IP
// address.
func CheckHost(host string) (string, error) {
	h := strings.ToLower(strings.TrimSpace(host))
	name, _ := strings.CutPrefix(h, "*.")
	bad := fmt.Errorf("%q is not a host: use a DNS name such as example.com, or *. and a name such as *.example.com", host)
	labels := strings.Split(name, ".")
	if name == "" || len(name) > 253 || len(labels) < 2 {
		return "", bad
	}
	// A name ends in a letter label. All digits is an IP address.
	if strings.Trim(labels[len(labels)-1], "0123456789") == "" {
		return "", bad
	}
	for _, label := range labels {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' || strings.Trim(label, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
			return "", bad
		}
	}
	return h, nil
}

// addExtra adds the settings that pass the checks to the sets. It leaves out
// the others: the store can hold a value that an older version wrote.
func addExtra(home string, protected []string, x Extra, read, write, hosts *set) {
	for _, p := range x.Write {
		if _, abs, err := checkPath(home, p, protected); err == nil {
			abs = Real(abs)
			read.add(abs)
			write.add(abs)
		}
	}
	for _, p := range x.Read {
		if _, abs, err := checkPath(home, p, protected); err == nil {
			read.add(Real(abs))
		}
	}
	for _, h := range x.Hosts {
		if h, err := CheckHost(h); err == nil {
			hosts.add(h)
		}
	}
}
