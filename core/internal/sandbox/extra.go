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
// must not hold a glob character, a quote, or a control character, because
// the sandbox could read them as a pattern or as the end of the path.
func CheckPath(home, path string) (string, error) {
	text, _, err := checkPath(home, path)
	return text, err
}

// checkPath returns the clean text of a path, with ~/ kept, and its absolute
// form.
func checkPath(home, path string) (text, abs string, err error) {
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
	if exposes(Real(home), Real(abs)) {
		return "", "", fmt.Errorf("%q is not allowed: it is the home folder, a folder above it, the root, a credential folder, or a folder that holds one", path)
	}
	if rel, ok := strings.CutPrefix(abs, filepath.Clean(home)+string(filepath.Separator)); ok {
		return "~/" + rel, abs, nil
	}
	return abs, abs, nil
}

// exposes reports whether allowing path would open what the sandbox denies:
// what [opens] names, or a folder that holds a credential path.
func exposes(home, path string) bool {
	if opens(home, path) {
		return true
	}
	path = strings.ToLower(path)
	for _, c := range credentials {
		c = filepath.Join(strings.ToLower(home), strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(c, "~/"), "/**")))
		if within(c, path) {
			return true
		}
	}
	return false
}

// CheckHost checks a host of the settings and returns it in lower case. A host
// is a DNS name, or *. and a DNS name with at least two labels, so *.com is
// not a host. It is never *, a URL, or a name with a port.
func CheckHost(host string) (string, error) {
	h := strings.ToLower(strings.TrimSpace(host))
	name, wild := strings.CutPrefix(h, "*.")
	if name == "" || len(name) > 253 || (wild && !strings.Contains(name, ".")) {
		return "", fmt.Errorf("%q is not a host: use a DNS name such as example.com, or *. and a name such as *.example.com", host)
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' || strings.Trim(label, "abcdefghijklmnopqrstuvwxyz0123456789-") != "" {
			return "", fmt.Errorf("%q is not a host: use a DNS name such as example.com, or *. and a name such as *.example.com", host)
		}
	}
	return h, nil
}

// addExtra adds the settings that pass the checks to the sets. It leaves out
// the others: the store can hold a value that an older version wrote.
func addExtra(home string, x Extra, read, write, hosts *set) {
	for _, p := range x.Write {
		if _, abs, err := checkPath(home, p); err == nil {
			abs = Real(abs)
			read.add(abs)
			write.add(abs)
		}
	}
	for _, p := range x.Read {
		if _, abs, err := checkPath(home, p); err == nil {
			read.add(Real(abs))
		}
	}
	for _, h := range x.Hosts {
		if h, err := CheckHost(h); err == nil {
			hosts.add(h)
		}
	}
}
