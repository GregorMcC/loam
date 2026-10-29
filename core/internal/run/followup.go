package run

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/gitremote"
	"github.com/GregorMcC/loam/core/internal/intake"
	"github.com/GregorMcC/loam/core/internal/linear"
	"github.com/GregorMcC/loam/core/internal/store"
)

// followUpEvent is the kind of the run event that says how filing a
// follow-up went.
const followUpEvent = "followup"

// draftFollowUp is a follow-up as Claude drafts it. Target is the URL of a
// Linear link of the plot, and only for a run that has no issue to follow.
type draftFollowUp struct {
	Title  string `json:"title"`
	Body   string `json:"body"`
	Target string `json:"target"`
}

// linearLink is a Linear project or team link of a plot. Loam offers these
// to Claude as places for the follow-ups of a run that has no issue.
type linearLink struct {
	Label string
	URL   string
}

// linearLinks returns the Linear project and team links of the plot, in the
// order of the plot.
func linearLinks(plot store.Plot) []linearLink {
	var out []linearLink
	for _, l := range plot.Links {
		if _, ok := linear.ParseScope(l.Target); ok {
			out = append(out, linearLink{Label: strings.TrimSpace(l.Label), URL: l.Target})
		}
	}
	return out
}

// followUpPlace says where the follow-ups of a run are filed. Fixed is set
// when the issue of the run decides it, or when the plot has no Linear
// link. Else Claude picks one of Offered for each follow-up.
type followUpPlace struct {
	Fixed   *store.FollowUpTarget
	Offered []linearLink
}

// placeFollowUps decides where the follow-ups of the run are filed:
//   - a GitHub issue: the repo of the issue
//   - a Linear issue: the project of the issue
//   - else the Linear links of the plot, which Claude picks from
//   - else the GitHub repo of the run
func placeFollowUps(plot store.Plot, src *store.RunSource, repoID string) followUpPlace {
	if src != nil {
		switch src.Kind {
		case intake.GitHub:
			if repo, ok := github.ParseRepo(issueRepoURL(src.URL)); ok {
				return followUpPlace{Fixed: githubTarget(repo)}
			}
		case intake.Linear:
			return followUpPlace{Fixed: &store.FollowUpTarget{Kind: store.TargetLinear, Label: "the Linear project of " + src.Key}}
		}
	}
	if links := linearLinks(plot); len(links) > 0 {
		return followUpPlace{Offered: links}
	}
	return followUpPlace{Fixed: runRepoTarget(plot, repoID)}
}

// issueRepoURL is the web URL of the repo of a GitHub issue URL.
func issueRepoURL(issueURL string) string {
	repo, _, _ := strings.Cut(issueURL, "/issues/")
	return repo
}

func githubTarget(repo github.Repo) *store.FollowUpTarget {
	return &store.FollowUpTarget{Kind: store.TargetGitHub, Label: repo.Owner + "/" + repo.Name, URL: "https://github.com/" + repo.Owner + "/" + repo.Name}
}

// runRepoTarget is the GitHub repo of the repo of the run. A repo with no
// GitHub origin gives a target with no URL, and filing says why it fails.
func runRepoTarget(plot store.Plot, repoID string) *store.FollowUpTarget {
	i := slices.IndexFunc(plot.Repos, func(repo store.Repo) bool { return repo.ID == repoID })
	if i < 0 {
		return &store.FollowUpTarget{Kind: store.TargetGitHub}
	}
	if web, ok := gitremote.Origin(plot.Repos[i].Path); ok {
		if repo, ok := github.ParseRepo(web); ok {
			return githubTarget(repo)
		}
	}
	return &store.FollowUpTarget{Kind: store.TargetGitHub, Label: repoName(plot.Repos[i]) + " (no GitHub origin)"}
}

// setFollowUps puts the follow-ups of the draft in the run, all kept. A
// follow-up with no title is left out. place is from [placeFollowUps], which
// can run git, so a caller makes it before it opens a store transaction.
func setFollowUps(place followUpPlace, r *store.Run, items []draftFollowUp) {
	r.Shape.FollowUps = make([]store.FollowUp, 0, len(items))
	for _, it := range items {
		title := strings.TrimSpace(it.Title)
		if title == "" {
			continue
		}
		var target store.FollowUpTarget
		if place.Fixed != nil {
			target = *place.Fixed
		} else {
			target = pickLinearTarget(place.Offered, it.Target)
		}
		r.Shape.FollowUps = append(r.Shape.FollowUps, store.FollowUp{
			Title: title, Body: strings.TrimSpace(it.Body), Target: target, Kept: true})
	}
}

// pickLinearTarget returns the offered link that pick names, by its URL or
// its label. A pick that matches none gives the first link, because Claude
// cannot be sure of a link that it has misspelled.
func pickLinearTarget(offered []linearLink, pick string) store.FollowUpTarget {
	pick = strings.TrimSpace(pick)
	i := slices.IndexFunc(offered, func(l linearLink) bool {
		return pick != "" && (l.URL == pick || strings.EqualFold(l.Label, pick))
	})
	l := offered[max(i, 0)]
	return store.FollowUpTarget{Kind: store.TargetLinear, Label: l.Label, URL: l.URL}
}

// writeFollowUpAdvice tells Claude what the follow_ups field holds, and
// where Loam files them.
func writeFollowUpAdvice(b *strings.Builder, plot store.Plot, r store.Run) {
	place := placeFollowUps(plot, r.Source, r.Shape.Repo)
	if len(place.Offered) == 0 {
		return
	}
	b.WriteString("\nLoam files each follow-up as a Linear issue in a project of the plot. Set the target of each follow-up to the URL of " +
		"the project that fits the work best. The projects:\n")
	for _, l := range place.Offered {
		fmt.Fprintf(b, "- %s: %s\n", cmp.Or(l.Label, "Linear"), l.URL)
	}
}

// fileFollowUps files each kept follow-up of the run that Loam has not filed
// yet, and records the issue or the error in the follow-up. Each result is a
// "followup" event. It returns the run as it is now, and a warning for each
// follow-up that Loam could not file. A failure never stops the run.
func fileFollowUps(ctx context.Context, s *store.Store, r store.Run) (store.Run, []string) {
	if r.Shape == nil {
		return r, nil
	}
	f := &filer{ctx: ctx, run: r}
	results := make(map[int]store.FollowUp)
	var warnings []string
	for i, fu := range r.Shape.FollowUps {
		if !fu.Kept || fu.Filed != nil {
			continue
		}
		fu.Filed, fu.Error = f.file(fu)
		detail := fmt.Sprintf("Filed %q as %s", fu.Title, filedKey(fu))
		if fu.Error != "" {
			detail = fmt.Sprintf("Could not file %q: %s", fu.Title, fu.Error)
			warnings = append(warnings, detail)
		}
		if err := s.AddRunEvent(r.ID, followUpEvent, detail); err != nil {
			warnings = append(warnings, err.Error())
		}
		results[i] = fu
	}
	if len(results) == 0 {
		return r, warnings
	}
	updated, err := s.UpdateRun(r.ID, func(r *store.Run) error {
		for i, fu := range results {
			if r.Shape != nil && i < len(r.Shape.FollowUps) {
				r.Shape.FollowUps[i] = fu
			}
		}
		return nil
	})
	if err != nil {
		return r, append(warnings, "Loam filed follow-ups but could not record them: "+err.Error())
	}
	return updated, warnings
}

// filedKey is the key of the issue of a follow-up, for an event.
func filedKey(fu store.FollowUp) string {
	if fu.Filed == nil {
		return ""
	}
	return fu.Filed.Key
}

// filer files follow-ups. It makes the Linear and GitHub clients when it
// first needs them, and keeps the home of each Linear target.
type filer struct {
	ctx   context.Context
	run   store.Run
	linC  *linear.Client
	linE  error
	ghC   *github.Client
	ghE   error
	homes map[string]linear.Home
}

// file makes the issue of one follow-up. It returns the issue, or why there
// is none. An issue that Loam made but could not link to the issue of the
// run comes with a reason.
func (f *filer) file(fu store.FollowUp) (*store.FiledIssue, string) {
	if fu.Target.Kind == store.TargetLinear {
		return f.fileLinear(fu)
	}
	return f.fileGitHub(fu)
}

func (f *filer) fileLinear(fu store.FollowUp) (*store.FiledIssue, string) {
	if f.linC == nil && f.linE == nil {
		f.linC, f.linE = linear.FromKeychain()
	}
	if f.linE != nil {
		return nil, f.linE.Error()
	}
	home, err := f.linearHome(fu.Target)
	if err != nil {
		return nil, err.Error()
	}
	src := f.run.Source
	body := fu.Body
	if body != "" {
		body += "\n\n"
	}
	body += fmt.Sprintf("Left out of the Loam run %q on purpose.", f.run.Title)
	made, err := f.linC.CreateIssue(f.ctx, linear.NewIssue{Home: home, Title: fu.Title, Description: body})
	if err != nil {
		return nil, err.Error()
	}
	filed := &store.FiledIssue{Key: made.Key, URL: made.URL}
	if src != nil && src.Kind == intake.Linear && home.IssueID != "" {
		if err := f.linC.Relate(f.ctx, made.ID, home.IssueID); err != nil {
			return filed, fmt.Sprintf("Loam made %s but could not link it to %s: %v", made.Key, src.Key, err)
		}
	}
	return filed, ""
}

// linearHome returns the team and project for the target. A target with no
// URL is the project of the Linear issue of the run.
func (f *filer) linearHome(t store.FollowUpTarget) (linear.Home, error) {
	if h, ok := f.homes[t.URL]; ok {
		return h, nil
	}
	var h linear.Home
	var err error
	if t.URL == "" {
		if f.run.Source == nil || f.run.Source.Kind != intake.Linear {
			return h, fmt.Errorf("the follow-up has no Linear project")
		}
		h, err = f.linC.HomeOfIssue(f.ctx, f.run.Source.Key)
	} else {
		scope, ok := linear.ParseScope(t.URL)
		if !ok {
			return h, fmt.Errorf("%s is not a Linear project or team page", t.URL)
		}
		h, err = f.linC.HomeOfScope(f.ctx, scope)
	}
	if err != nil {
		return h, err
	}
	if f.homes == nil {
		f.homes = map[string]linear.Home{}
	}
	f.homes[t.URL] = h
	return h, nil
}

func (f *filer) fileGitHub(fu store.FollowUp) (*store.FiledIssue, string) {
	repo, ok := github.ParseRepo(fu.Target.URL)
	if !ok {
		return nil, "the repo of the run has no GitHub origin, so Loam has no repo to file the issue in"
	}
	if f.ghC == nil && f.ghE == nil {
		f.ghC, f.ghE = github.NewClient()
	}
	if f.ghE != nil {
		return nil, f.ghE.Error()
	}
	body := fu.Body
	if body != "" {
		body += "\n\n"
	}
	body += "Left out of " + followUpSource(f.run) + " on purpose."
	made, err := f.ghC.CreateIssue(f.ctx, repo, github.NewIssue{Title: fu.Title, Body: body})
	if err != nil {
		return nil, err.Error()
	}
	return &store.FiledIssue{Key: fmt.Sprintf("%s/%s#%d", repo.Owner, repo.Name, made.Number), URL: made.URL}, ""
}

// followUpSource names the source of the run for the body of a GitHub issue:
// its GitHub issue, else the run. It names no Linear issue and no path,
// because the repo can be public.
func followUpSource(r store.Run) string {
	if src := r.Source; src != nil && src.Kind == intake.GitHub {
		return "issue " + src.Key
	}
	return fmt.Sprintf("the Loam run %q", r.Title)
}

// prFollowUps is the Follow-ups section of the PR body of a run: each issue
// that Loam filed. A Linear issue is its key only, with no title, because the
// workspace can be private and the repo public. It is empty when Loam filed
// none.
func prFollowUps(r store.Run, repo github.Repo) string {
	if r.Shape == nil {
		return ""
	}
	var b strings.Builder
	for _, fu := range r.Shape.FollowUps {
		if fu.Filed == nil {
			continue
		}
		if fu.Target.Kind == store.TargetLinear {
			fmt.Fprintf(&b, "- %s\n", fu.Filed.Key)
			continue
		}
		fmt.Fprintf(&b, "- %s: %s\n", strings.TrimPrefix(fu.Filed.Key, repo.Owner+"/"+repo.Name), fu.Title)
	}
	if b.Len() == 0 {
		return ""
	}
	return "\n## Follow-ups\n\nWork that this PR leaves out on purpose:\n\n" + b.String()
}
