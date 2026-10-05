// Package linkkind says what a link target is and opens it.
//
// A target is a URL or a local path. A URL has a kind from its host: notion,
// linear, github, or url for any other. A local path is a vault link when an
// Obsidian vault holds it, and a path link when none does.
package linkkind

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// The kinds of link. They are stable: the app and the MCP tools return them.
const (
	Notion = "notion"
	Linear = "linear"
	GitHub = "github"
	URL    = "url"
	Path   = "path"
	Vault  = "vault"
)

// Info says what a link target is.
type Info struct {
	// Kind is one of the kind constants.
	Kind string
	// Local is true for a path or vault link.
	Local bool
	// Target is the target without space around it. A local target has a
	// leading ~ expanded and is cleaned: it is an absolute path.
	Target string
	// Path is Target for a local link, else empty.
	Path string
	// Exists says whether a local path exists. It is false for a URL.
	Exists bool
	// IsDir says whether a local path that exists is a folder.
	IsDir bool
	// Vault is the root of the most specific vault that holds a vault link.
	Vault string
}

// IsLocal says whether a link target is a local path: absolute, or with a
// leading ~. Any other target is a URL.
func IsLocal(target string) bool {
	t := strings.TrimSpace(target)
	return strings.HasPrefix(t, "/") || t == "~" || strings.HasPrefix(t, "~/")
}

// Expand returns the target with a leading ~ replaced by the home folder.
// A local path is also cleaned. Any other target comes back trimmed.
func Expand(target string) string {
	t := strings.TrimSpace(target)
	if !IsLocal(t) {
		return t
	}
	if t == "~" || strings.HasPrefix(t, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			t = home + strings.TrimPrefix(t, "~")
		}
	}
	return filepath.Clean(t)
}

// Classify says what a target is. vaults are the roots of the Obsidian
// vaults, from [Vaults]. A local path counts as a vault link when a vault root
// is the path or a parent of it, even when the path does not exist. With more
// than one such vault, the deepest one wins.
func Classify(target string, vaults []string) Info {
	t := Expand(target)
	if !IsLocal(t) {
		return Info{Kind: urlKind(t), Target: t}
	}
	info := Info{Kind: Path, Local: true, Target: t, Path: t}
	if fi, err := os.Stat(t); err == nil {
		info.Exists, info.IsDir = true, fi.IsDir()
	}
	for _, v := range vaults {
		v = filepath.Clean(v)
		if within(v, t) && len(v) > len(info.Vault) {
			info.Kind, info.Vault = Vault, v
		}
	}
	return info
}

// within says whether path is root or a path below root.
func within(root, path string) bool {
	if root == "/" {
		return strings.HasPrefix(path, "/")
	}
	return path == root || strings.HasPrefix(path, root+"/")
}

// urlKind returns the kind of a non-local target, from its host.
func urlKind(target string) string {
	u, err := url.Parse(target)
	if err != nil {
		return URL
	}
	host := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	switch {
	case host == "notion.so" || host == "notion.site" || strings.HasSuffix(host, ".notion.so") || strings.HasSuffix(host, ".notion.site"):
		return Notion
	case host == "linear.app":
		return Linear
	case host == "github.com":
		return GitHub
	}
	return URL
}

// Vaults returns the roots of the Obsidian vaults. It reads the "vaults" map
// of ~/Library/Application Support/obsidian/obsidian.json. A missing or
// unreadable file gives no vaults.
func Vaults() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(home, "Library", "Application Support", "obsidian", "obsidian.json"))
	if err != nil {
		return nil
	}
	var cfg struct {
		Vaults map[string]struct {
			Path string `json:"path"`
		} `json:"vaults"`
	}
	if json.Unmarshal(b, &cfg) != nil {
		return nil
	}
	var out []string
	for _, v := range cfg.Vaults {
		if strings.HasPrefix(v.Path, "/") {
			out = append(out, filepath.Clean(v.Path))
		}
	}
	return out
}
