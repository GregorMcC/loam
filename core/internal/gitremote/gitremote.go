// Package gitremote finds the web page of a repo's git remote, so a repo
// that a plot adds can bring its remote as a link.
package gitremote

import (
	"context"
	"net/url"
	"os/exec"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/GregorMcC/loam/core/internal/store"
)

// scpLike matches the short SSH form, such as git@github.com:owner/repo.git.
var scpLike = regexp.MustCompile(`^(?:[^@/]+@)?([^:/]+):(.+)$`)

// WebURL turns a git remote URL into the web page of the repo. It drops a
// user name or a token, a trailing ".git", and an SSH port. It returns false
// for a local remote (a path or file://), which has no web page.
func WebURL(remote string) (string, bool) {
	remote = strings.TrimSpace(remote)
	scheme, host, p := "https", "", ""
	switch {
	case strings.Contains(remote, "://"):
		u, err := url.Parse(remote)
		if err != nil {
			return "", false
		}
		switch u.Scheme {
		case "http", "https":
			scheme, host = u.Scheme, u.Host
		case "ssh", "git", "git+ssh", "ssh+git":
			host = u.Hostname()
		default:
			return "", false
		}
		p = u.Path
	case scpLike.MatchString(remote):
		m := scpLike.FindStringSubmatch(remote)
		host, p = m[1], m[2]
	default:
		return "", false
	}
	p = strings.TrimSuffix(strings.Trim(p, "/"), ".git")
	if host == "" || p == "" {
		return "", false
	}
	return scheme + "://" + host + "/" + p, true
}

// Label names the link: the repo name, then where it lives, such as
// "loam on GitHub".
func Label(webURL string) string {
	u, err := url.Parse(webURL)
	if err != nil {
		return webURL
	}
	site := map[string]string{"github.com": "GitHub", "gitlab.com": "GitLab", "bitbucket.org": "Bitbucket"}[u.Hostname()]
	if site == "" {
		site = u.Host
	}
	return path.Base(u.Path) + " on " + site
}

// Find returns the web page of the repo's remote: origin, else the first
// remote. It returns false when the folder is not a git repo, has no
// remote, or the remote has no web page.
func Find(repoPath string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	git := func(args ...string) string {
		out, err := exec.CommandContext(ctx, "git", append([]string{"-C", repoPath}, args...)...).Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	name := "origin"
	if !strings.Contains("\n"+git("remote")+"\n", "\norigin\n") {
		name, _, _ = strings.Cut(git("remote"), "\n")
	}
	if name == "" {
		return "", false
	}
	return WebURL(git("remote", "get-url", name))
}

// LinkEdit returns the edit that adds the repo's remote as a link of p. It
// returns false when the repo has no web remote, or p already links it.
func LinkEdit(p store.Plot, repoPath string) (store.Edit, bool) {
	var targets []string
	for _, l := range p.Links {
		targets = append(targets, l.Target)
	}
	l, ok := link(repoPath, targets)
	if !ok {
		return store.Edit{}, false
	}
	return store.Edit{Op: store.OpAddLink, Label: store.S(l.Label), Target: store.S(l.Target), Note: store.S("")}, true
}

// AddLinks adds the remote of each repo to links, for a new plot. It skips a
// repo with no web remote and a remote that links already holds.
func AddLinks(links []store.LinkInput, repos []store.RepoInput) []store.LinkInput {
	for _, r := range repos {
		var targets []string
		for _, l := range links {
			targets = append(targets, l.Target)
		}
		if l, ok := link(r.Path, targets); ok {
			links = append(links, l)
		}
	}
	return links
}

func link(repoPath string, targets []string) (store.LinkInput, bool) {
	target, ok := Find(repoPath)
	if !ok {
		return store.LinkInput{}, false
	}
	for _, t := range targets {
		if strings.TrimSuffix(t, "/") == target {
			return store.LinkInput{}, false
		}
	}
	return store.LinkInput{Label: Label(target), Target: target}, true
}
