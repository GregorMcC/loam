package run

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

// CodeRabbitWait is how long a run whose CI passed waits for CodeRabbit when
// CodeRabbit did not review the head of its PR (see [codeRabbitMissed]).
// CodeRabbit reviews at most 10 commits an hour, so a wait can end in a
// review. After the wait, the run is Ready, and its note says that
// CodeRabbit did not review the head.
var CodeRabbitWait = 30 * time.Minute

// majorMark finds the header of a Critical or Major finding in the body of a
// review. CodeRabbit writes the severity in the header of each finding, also
// for a finding on a line outside the diff, which has no thread. It has two
// forms: an emoji, such as "_⚠️ Potential issue_ | _🟠 Major_", and an icon,
// an <img> in a <picture> before the word, such as
// "**<picture><img src=\".../major-16.svg\" ...></picture> Major**". A Minor
// or Trivial finding has another word. The mark is an emoji or the end of
// the <picture> before the word, or an emphasis that holds only the word,
// such as "**Major**". So the word in the text of a finding does not count,
// and nor does a bold title that starts with it, such as "**Critical section
// is not locked.**". No letter follows the word: "_" is a word character, so
// a word boundary does not end "_Major_".
var majorMark = regexp.MustCompile(severityPattern("🔴|🟠", "Critical|Major"))

// hasMajorFinding reports whether the body of a review has a Critical or
// Major finding.
func hasMajorFinding(body string) bool { return majorMark.MatchString(body) }

// severityMark finds the header of a finding of each severity, as
// [majorMark] does for Critical and Major.
var severityMark = regexp.MustCompile(severityPattern("🔴|🟠|🟡|🔵", "Critical|Major|Minor|Trivial"))

// severityPattern is the pattern of a finding header with one of the words,
// after one of the emojis or a <picture>, or alone in an emphasis (see
// [majorMark]).
func severityPattern(emojis, words string) string {
	return `(?:(?:` + emojis + `|</picture>)\s*(?:` + words + `)(?:[^\pL]|$)|[_*]{1,2}(?:` + words + `)[_*]{1,2})`
}

// reviewText is the text of a review body that goes to the session. It is
// the body, which [quote] cuts to [reviewTextMax] characters, when the body
// fits, or when the cut keeps all of the last Critical or Major finding.
// Else, such as after a long list of nitpicks or with a finding that the cut
// ends, it is only the Critical and Major findings (see [majorFindings]),
// and excerpt is true. Loam records a review as sent, so a finding in the
// cut part would never reach the session.
func reviewText(body string) (text string, excerpt bool) {
	spans := majorSpans(body)
	// quote keeps reviewTextMax-1 characters of a body that it cuts.
	if utf8.RuneCountInString(body) <= reviewTextMax || len(spans) == 0 ||
		utf8.RuneCountInString(body[:spans[len(spans)-1].end]) < reviewTextMax {
		return body, false
	}
	return majorFindings(body, spans), true
}

// span is the part of a review body from start to end, as byte indexes.
type span struct{ start, end int }

// majorSpans are the Critical and Major findings of a review body. A finding
// is the text from the line of its header to the line of the next header of
// any severity, or to the end of the body.
func majorSpans(body string) []span {
	marks := severityMark.FindAllStringIndex(body, -1)
	var spans []span
	for i, m := range marks {
		if !majorMark.MatchString(body[m[0]:m[1]]) {
			continue
		}
		sp := span{start: lineStart(body, m[0]), end: len(body)}
		for _, n := range marks[i+1:] {
			if next := lineStart(body, n[0]); next > sp.start {
				sp.end = next
				break
			}
		}
		spans = append(spans, sp)
	}
	return spans
}

// majorFindings is the text of the findings of body at spans (see
// [majorSpans]). The file of a finding is in a line before it (see
// [fileOf]), so that line goes first. Each finding gets an even part of
// [reviewTextMax], so a long finding does not leave out the others.
func majorFindings(body string, spans []span) string {
	if len(spans) == 0 {
		return ""
	}
	// The parts and the blank lines between them fit in reviewTextMax.
	share := (reviewTextMax - 2*(len(spans)-1)) / len(spans)
	parts := make([]string, len(spans))
	for i, sp := range spans {
		part := strings.TrimSpace(body[sp.start:sp.end])
		if file := fileOf(body[:sp.start]); file != "" {
			part = file + "\n" + part
		}
		parts[i] = truncate(part, share)
	}
	return strings.Join(parts, "\n\n")
}

// fileLine is a line of CodeRabbit that names the file of the findings below
// it, once its HTML tags are removed. It has two forms: the file with the
// count of its findings, such as "core/run.go (2)", and the file with the
// lines and the count of a finding, such as "core/run.go-213-214: 1". A path
// has no space, so a line such as "Nitpick comments (3)" does not count, and
// nor does the summary of the prompt for AI agents of a finding.
var fileLine = regexp.MustCompile(`^[^\s:()<>]+(?: \(\d+\)|-\d+(?:-\d+)?: \d+)$`)

// htmlTag is an HTML tag, such as <summary> or </code>.
var htmlTag = regexp.MustCompile(`<[^>\n]*>`)

// fileOf is the last line of text that names a file (see [fileLine]), with
// its HTML tags and quote marks removed, or "" when text has none.
func fileOf(text string) string {
	lines := strings.Split(text, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimLeft(strings.TrimSpace(htmlTag.ReplaceAllString(lines[i], "")), "> ")
		if fileLine.MatchString(line) {
			return line
		}
	}
	return ""
}

// lineStart is the index of the start of the line that holds index i.
func lineStart(text string, i int) int { return strings.LastIndex(text[:i], "\n") + 1 }

// majorReviews are the reviews of apps that only comment, on the head of pr
// (see [github.PR.CommentReviews]), whose body has a Critical or Major
// finding, and that Loam has not sent to the run r yet.
func majorReviews(r store.Run, pr *github.PR) []github.Review {
	var out []github.Review
	for _, c := range pr.CommentReviews {
		if hasMajorFinding(c.Body) && !slices.Contains(r.ReviewsSent, c.ID) {
			out = append(out, c)
		}
	}
	return out
}

// isCodeRabbit reports whether the login of an app, or the name of a check,
// is of CodeRabbit.
func isCodeRabbit(name string) bool { return strings.HasPrefix(strings.ToLower(name), "coderabbit") }

// codeRabbitNotice finds the heading of a notice of CodeRabbit that it did
// not review: "## Reviews paused", or "## Rate limit exceeded" for its review
// limit. A notice is a quote, so "> " can come before the heading. Only a
// heading counts: the summary comment of CodeRabbit also describes the PR,
// and a PR can be about these words.
var codeRabbitNotice = regexp.MustCompile(`(?mi)^[>\s]*#{1,6}\s*(reviews paused|rate limit exceeded|review limit reached)\s*$`)

// codeRabbitMissed says why CodeRabbit did not review the head of pr, or ""
// when nothing says so: its check on the head was skipped, or its last
// comment on the PR has the notice that its reviews are paused or that it
// reached its review limit (see [codeRabbitNotice]). CodeRabbit edits its
// comments, so its last comment is the one that it edited or wrote last (see
// [github.PR.AppComments]). A review of CodeRabbit on the head says that it
// reviewed the head, whatever its check or its comment says.
func codeRabbitMissed(pr *github.PR) string {
	if codeRabbitReviewed(pr) {
		return ""
	}
	for _, c := range pr.PassedChecks {
		if c.Skipped && isCodeRabbit(c.Name) {
			return "its check was skipped"
		}
	}
	for _, c := range pr.AppComments {
		if !isCodeRabbit(c.Author) {
			continue
		}
		m := codeRabbitNotice.FindStringSubmatch(c.Body)
		switch {
		case m == nil:
		case strings.EqualFold(m[1], "reviews paused"):
			return "its reviews are paused"
		default:
			return "it reached its review limit"
		}
	}
	return ""
}

// codeRabbitReviewed reports whether pr has a review of CodeRabbit on its
// head: a review that only comments, or one that requests changes.
func codeRabbitReviewed(pr *github.PR) bool {
	for _, c := range pr.CommentReviews {
		if isCodeRabbit(c.Author) {
			return true
		}
	}
	for _, c := range pr.ChangeRequests {
		if isCodeRabbit(c.Author) && c.Commit == pr.HeadOID {
			return true
		}
	}
	return false
}

// waitForCodeRabbit keeps the run in Shipping while CodeRabbit did not review
// the head of pr, for why, until [CodeRabbitWait] after the first tick that
// found it. That tick sets the note of the run and adds a review event,
// which holds the head, so a new head waits again. wait is false when the
// wait is over.
func (sh *shipper) waitForCodeRabbit(pr *github.PR, why string) (wait, moved bool, err error) {
	mark := fmt.Sprintf("CodeRabbit did not review %s, the head of #%d", shortOID(pr.HeadOID), pr.Number)
	if since, ok := sh.sinceFirst("review", mark); ok {
		return since < CodeRabbitWait, false, nil
	}
	note := fmt.Sprintf("%s: %s. Loam waits up to %d minutes for its review", mark, why, int(CodeRabbitWait.Minutes()))
	moved, err = sh.update(func(r *store.Run) { r.Note = note })
	if !moved || err != nil {
		return true, moved, err
	}
	return true, moved, sh.s.AddRunEvent(sh.r.ID, "review", note)
}

// sinceFirst is how long ago the run got its first event of the kind whose
// detail starts with prefix. ok is false when it has none.
func (sh *shipper) sinceFirst(kind, prefix string) (since time.Duration, ok bool) {
	events, err := sh.s.RunEvents(sh.r.ID)
	if err != nil {
		return 0, false
	}
	for _, e := range events {
		if e.Kind == kind && strings.HasPrefix(e.Detail, prefix) {
			return time.Since(e.At), true
		}
	}
	return 0, false
}

// shortOID is the first 7 characters of a commit ID.
func shortOID(oid string) string { return oid[:min(len(oid), 7)] }

// olderChangeRequest is the part of a Ready note that says that the review
// decision of pr is CHANGES_REQUESTED only because of a review of an older
// commit: each review that requests changes is of a commit before the head.
// GitHub keeps the decision until the reviewer reviews again, so a bot that
// did not review the head again leaves it. It is "" otherwise, and also when
// GitHub gives no commit of a review.
func olderChangeRequest(pr *github.PR) string {
	if pr.ReviewDecision != changesRequested || len(pr.ChangeRequests) == 0 {
		return ""
	}
	var authors []string
	for _, c := range pr.ChangeRequests {
		if c.Commit == "" || c.Commit == pr.HeadOID {
			return ""
		}
		if !slices.Contains(authors, c.Author) {
			authors = append(authors, c.Author)
		}
	}
	return fmt.Sprintf(". Changes are requested on #%d only by a review of an older commit, by %s", pr.Number, joinAnd(authors))
}
