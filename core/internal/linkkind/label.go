package linkkind

import (
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// notionID is the page ID at the end of a Notion URL, with the dash before it.
var notionID = regexp.MustCompile(`-?[0-9a-f]{32}$`)

// Label names a link from its target, for a link added with no label:
//   - a local path: the file name with no extension, or the folder name.
//   - GitHub: "<repo> on GitHub", "<repo>#<n>" for an issue or pull request,
//     or the file or folder name for a blob or tree.
//   - Linear: the issue ID.
//   - Notion: the page title from the URL.
//   - Obsidian: the note name.
//   - any other URL: the host.
//
// A target with no better name comes back trimmed.
func Label(target string) string {
	t := strings.TrimSpace(target)
	if IsLocal(t) {
		return pathLabel(Expand(t))
	}
	u, err := url.Parse(t)
	if err != nil || u.Host == "" && u.Scheme != "obsidian" {
		return t
	}
	host := strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
	parts := strings.FieldsFunc(u.Path, func(r rune) bool { return r == '/' })
	switch kind := urlKind(t); {
	case u.Scheme == "obsidian":
		if f := u.Query().Get("file"); f != "" {
			return strings.TrimSuffix(path.Base(f), ".md")
		}
		if v := u.Query().Get("vault"); v != "" {
			return v
		}
	case kind == GitHub:
		return githubLabel(parts)
	case kind == Linear:
		if len(parts) >= 3 && parts[1] == "issue" {
			return parts[2]
		}
		return "Linear"
	case kind == Notion:
		if len(parts) > 0 {
			if title := strings.ReplaceAll(notionID.ReplaceAllString(parts[len(parts)-1], ""), "-", " "); title != "" {
				return title
			}
		}
		return "Notion page"
	}
	if u.Port() != "" {
		return host + ":" + u.Port()
	}
	if host == "" {
		return t
	}
	return host
}

func pathLabel(p string) string {
	base := filepath.Base(p)
	if base == "/" || base == "." {
		return base
	}
	if fi, err := os.Stat(p); err == nil && fi.IsDir() {
		return base
	}
	// A dot file such as .env has no extension to drop.
	if ext := filepath.Ext(base); ext != base {
		return strings.TrimSuffix(base, ext)
	}
	return base
}

func githubLabel(parts []string) string {
	switch {
	case len(parts) == 0:
		return "GitHub"
	case len(parts) == 1:
		return parts[0] + " on GitHub"
	case len(parts) >= 4 && (parts[2] == "issues" || parts[2] == "pull"):
		return parts[1] + "#" + parts[3]
	case len(parts) >= 5 && (parts[2] == "blob" || parts[2] == "tree"):
		return pathLabel(parts[len(parts)-1])
	}
	return parts[1] + " on GitHub"
}
