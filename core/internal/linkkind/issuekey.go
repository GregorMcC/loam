package linkkind

import (
	"net/url"
	"regexp"
	"strings"
)

// linearID is the shape of a Linear issue ID, such as ENG-482.
var linearID = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9]*-[0-9]+$`)

// githubNumber is the shape of a GitHub issue number.
var githubNumber = regexp.MustCompile(`^[0-9]+$`)

// githubName is the shape of a GitHub owner or repo name. A name with any
// other character, such as a control character, is not an issue link.
var githubName = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// IssueKey returns the key of an issue link, which a PR body puts after
// "Fixes". For a Linear issue it is the ID, such as "ENG-482". For a GitHub
// issue it is "#57" when the issue is in repo, else "owner/repo#57", because
// GitHub reads "#57" as an issue of the PR's repo. repo is the web page of
// the repo that the PR goes to, such as "https://github.com/example/widgets",
// or "". IssueKey returns "" for any other target, a GitHub pull request
// included.
func IssueKey(target, repo string) string {
	t := strings.TrimSpace(target)
	if IsLocal(t) {
		return ""
	}
	u, err := url.Parse(t)
	if err != nil {
		return ""
	}
	parts := pathParts(u)
	switch urlKind(t) {
	case Linear:
		if len(parts) >= 3 && parts[1] == "issue" && linearID.MatchString(parts[2]) {
			return strings.ToUpper(parts[2])
		}
	case GitHub:
		if len(parts) >= 4 && parts[2] == "issues" && githubNumber.MatchString(parts[3]) &&
			githubName.MatchString(parts[0]) && githubName.MatchString(parts[1]) {
			if sameGitHubRepo(repo, parts[0], parts[1]) {
				return "#" + parts[3]
			}
			return parts[0] + "/" + parts[1] + "#" + parts[3]
		}
	}
	return ""
}

// sameGitHubRepo reports whether repo is the web page of the GitHub repo
// owner/name. GitHub names do not depend on case.
func sameGitHubRepo(repo, owner, name string) bool {
	if urlKind(repo) != GitHub {
		return false
	}
	u, err := url.Parse(repo)
	if err != nil {
		return false
	}
	parts := pathParts(u)
	return len(parts) == 2 && strings.EqualFold(parts[0], owner) && strings.EqualFold(parts[1], name)
}

// pathParts returns the parts of the path of u, with no empty part.
func pathParts(u *url.URL) []string {
	return strings.FieldsFunc(u.Path, func(r rune) bool { return r == '/' })
}
