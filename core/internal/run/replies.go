package run

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
)

// The session of a run cannot reach GitHub, so it writes its replies to a
// review that Loam sent back to a file, and Loam posts them. The file is
// repliesFolder/repliesName below the git folder of the run folder: git
// never commits it, and the sandbox of the session can write there.
const (
	repliesFolder = "loam"
	repliesName   = "review-replies.json"
)

// repliesFileMax is the most bytes of the replies file that Loam reads.
const repliesFileMax = 1 << 20

// repliesMax is the most thread replies that the file can hold: twice the
// most threads that Loam sends, one page of GitHub, so a thread with two
// replies does not lose the file.
const repliesMax = 200

// replyTextMax is the most characters of one reply, or of the comment, that
// Loam posts. Loam cuts a longer text.
const replyTextMax = 8000

// reviewReplies is the replies file, in the format that [repliesText] gives
// the session. Loam takes all of it as untrusted.
type reviewReplies struct {
	Threads []threadReply `json:"threads"`
	// Comment is the one comment on the PR for the points in the body of a
	// review.
	Comment string `json:"comment"`
}

// threadReply is the reply of the session on one review thread.
type threadReply struct {
	ID      string `json:"id"`
	Body    string `json:"body"`
	Resolve bool   `json:"resolve"`
}

// repliesDir is the git folder of a run in folder, a worktree of repo,
// which holds the replies file. The session can change the .git file of its
// worktree, so the git folder must be in the git folder of repo. Loam reads
// and removes the file through an [os.Root] of the folder, so no link takes
// it out of the folder.
func repliesDir(ctx context.Context, folder, repo string) (string, error) {
	dir, err := realGitDir(ctx, folder, "--absolute-git-dir")
	if err != nil {
		return "", err
	}
	common, err := realGitDir(ctx, repo, "--git-common-dir")
	if err != nil {
		return "", err
	}
	if rel, err := filepath.Rel(common, dir); err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("the git folder %s of the run is not in the git folder %s of the repo", dir, common)
	}
	return dir, nil
}

// repliesPath is the replies file in the git folder dir, as the prompt and
// the events name it.
func repliesPath(dir string) string { return filepath.Join(dir, repliesFolder, repliesName) }

// repliesFile is the replies file in the root of a git folder.
const repliesFile = repliesFolder + "/" + repliesName

// realGitDir is the git folder that git rev-parse gives for the flag in dir,
// as an absolute path with no links.
func realGitDir(ctx context.Context, dir, flag string) (string, error) {
	out, err := gitOut(ctx, dir, "rev-parse", "--path-format=absolute", flag)
	if err != nil {
		return "", fmt.Errorf("git cannot find the git folder of %s: %w", dir, err)
	}
	return filepath.EvalSymlinks(out)
}

// clearReplies removes the replies file in the git folder dir, and makes
// its folder, so the session only writes the file. When the folder is not a
// folder, such as a link, it removes it, and nothing that a link points to.
func clearReplies(dir string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	fi, err := root.Lstat(repliesFolder)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		err = nil
	case err != nil:
		return err
	case !fi.IsDir():
		err = root.Remove(repliesFolder)
	default:
		err = root.RemoveAll(repliesFile)
	}
	if err != nil {
		return err
	}
	return root.MkdirAll(repliesFolder, 0o700)
}

// readReplies reads the replies file in the git folder dir. A missing file
// gives an error that is [fs.ErrNotExist]. Loam reads a file, not a link,
// and nothing out of dir.
func readReplies(dir string) (reviewReplies, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return reviewReplies{}, err
	}
	defer root.Close()
	if fi, err := root.Lstat(repliesFile); err != nil {
		return reviewReplies{}, err
	} else if !fi.Mode().IsRegular() {
		return reviewReplies{}, errors.New("it is not a file")
	}
	// No wait on a pipe that took the place of the file.
	f, err := root.OpenFile(repliesFile, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return reviewReplies{}, err
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil {
		return reviewReplies{}, err
	} else if !fi.Mode().IsRegular() {
		return reviewReplies{}, errors.New("it is not a file")
	}
	b, err := io.ReadAll(io.LimitReader(f, repliesFileMax+1))
	if err != nil {
		return reviewReplies{}, err
	}
	if len(b) > repliesFileMax {
		return reviewReplies{}, fmt.Errorf("it has more than %d bytes", repliesFileMax)
	}
	var rr reviewReplies
	if err := json.Unmarshal(b, &rr); err != nil {
		return reviewReplies{}, fmt.Errorf("it is not JSON in the format of the prompt: %v", err)
	}
	if len(rr.Threads) > repliesMax {
		return reviewReplies{}, fmt.Errorf("it has %d thread replies, and the most is %d", len(rr.Threads), repliesMax)
	}
	return rr, nil
}

// repliesText tells the session to write its replies to the review held to
// the file at path, and gives the format. held has threads, reviews, or
// both.
func repliesText(path string, held review) string {
	var asks, fields []string
	if len(held.threads) > 0 {
		asks = append(asks, "Give each thread above one reply, with what you did or why the code stays. "+
			"Set resolve to true, unless the thread says to leave it open.")
		fields = append(fields, `"threads": [{"id": "<thread ID>", "body": "<reply>", "resolve": true}]`)
	}
	if len(held.requests) > 0 {
		asks = append(asks, "A point in the body of a review has no thread. For the points in a review body that stay as they are, "+
			"say why in comment, and Loam posts it as one comment on the PR.")
		fields = append(fields, `"comment": "<comment>"`)
	}
	return fmt.Sprintf("%s Write the replies as JSON to this file. Use Bash, because the file is outside the folder of the run:\n\n"+
		"%s\n\n```json\n{%s}\n```\n\nDo not run gh: Loam posts the replies on GitHub after it pushes the fix. ",
		strings.Join(asks, " "), path, strings.Join(fields, ", "))
}

// postReplies posts the replies that the session wrote to the review that
// Loam sent back, as the user of gh. Loam calls it when the PR shows the
// head of the branch: after it pushed the fix, or when the session made no
// commit. repo is the repo of the run on GitHub, and w its worktree.
//
// Loam posts only to the threads that it sent, it resolves a thread only
// when the session asks and the prompt held all of the thread, and it posts
// the comment only when the prompt held a review. When GitHub is out of
// reach, Loam records what it posted, and returns an error: the next tick
// posts the rest. Else it clears what it sent from the run, and a "review"
// event says what it did. A missing, bad, or partly posted file does not
// stop the run. Loam removes the file when it has posted all of it, else the
// file stays for you, and a post that GitHub refused is a warning. It
// returns pr with no thread that Loam resolved, for the steps after it.
func (sh *shipper) postReplies(ctx context.Context, repo github.Repo, w store.Worktree, pr *github.PR) (*github.PR, error) {
	if sh.r.ReviewReplies.PR != pr.Number {
		return pr, sh.endReplies(fmt.Sprintf("The review replies are for #%d, so Loam posted none on #%d", sh.r.ReviewReplies.PR, pr.Number))
	}
	dir, err := repliesDir(ctx, sh.r.Folder, w.Repo)
	if err != nil {
		return pr, sh.endReplies(fmt.Sprintf("Loam posted no review replies on #%d: %v", pr.Number, err))
	}
	path := repliesPath(dir)
	rr, err := readReplies(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return pr, sh.endReplies(fmt.Sprintf("The session wrote no review replies, so Loam posted none on #%d", pr.Number))
	case err != nil:
		return pr, sh.endReplies(fmt.Sprintf("Loam posted no review replies on #%d: the file %s: %v", pr.Number, path, err))
	}
	sent := *sh.r.ReviewReplies
	sent.Replied = slices.Clone(sent.Replied)
	p := sh.post(ctx, repo, pr.Number, &sent, rr)
	if p.retry != nil {
		if _, err := sh.update(func(r *store.Run) { r.ReviewReplies = &sent }); err != nil {
			return pr, err
		}
		return pr, fmt.Errorf("Loam posts the review replies on #%d on the next tick: %w", pr.Number, p.retry)
	}
	detail := p.summary(pr.Number)
	if len(p.failed) > 0 {
		detail += fmt.Sprintf(". %s failed, the first with: %s. The replies stay in %s", count(len(p.failed), "post"), p.failed[0], path)
		sh.warnings = append(sh.warnings, sh.r.Title+": "+detail)
	} else if err := clearReplies(dir); err != nil {
		sh.warnings = append(sh.warnings, fmt.Sprintf("%s: Loam could not remove %s: %v", sh.r.Title, path, err))
	}
	if err := sh.endReplies(detail); err != nil {
		return pr, err
	}
	open := *pr
	open.ReviewThreads = slices.DeleteFunc(slices.Clone(pr.ReviewThreads), func(t github.ReviewThread) bool {
		return slices.Contains(p.resolved, t.ID)
	})
	return &open, nil
}

// endReplies clears what Loam sent back from the run, and adds the "review"
// event with the detail.
func (sh *shipper) endReplies(detail string) error {
	if moved, err := sh.update(func(r *store.Run) { r.ReviewReplies = nil }); !moved || err != nil {
		return err
	}
	return sh.s.AddRunEvent(sh.r.ID, "review", detail)
}

// posted is what [shipper.post] did with the replies file.
type posted struct {
	replies  int
	resolved []string
	comment  bool
	// left counts the replies that Loam did not post, because they are for
	// a thread or a review that Loam did not send, or repeat a thread.
	left int
	// failed are the posts that GitHub refused.
	failed []string
	// retry is the error of a post that Loam can try again, such as with no
	// network. Loam stops at it.
	retry error
}

// post posts the replies in rr that are for what Loam sent, on the PR with
// the number. An entry with no text posts no reply, and can still resolve
// its thread. It records each reply and
// the comment in sent, and does not post them again.
func (sh *shipper) post(ctx context.Context, repo github.Repo, number int, sent *store.RunReviewReplies, rr reviewReplies) posted {
	var p posted
	// fail records err, and reports whether Loam can go on.
	fail := func(err error) bool {
		if ctx.Err() != nil || errors.Is(err, github.ErrOffline) || errors.Is(err, github.ErrRateLimited) ||
			errors.Is(err, github.ErrSignedOut) || errors.Is(err, github.ErrGHMissing) {
			p.retry = err
			return false
		}
		p.failed = append(p.failed, err.Error())
		return true
	}
	seen := map[string]bool{}
	for _, t := range rr.Threads {
		body := strings.TrimSpace(t.Body)
		if !slices.Contains(sent.Threads, t.ID) || seen[t.ID] {
			if body != "" || t.Resolve {
				p.left++
			}
			continue
		}
		seen[t.ID] = true
		if body != "" && !slices.Contains(sent.Replied, t.ID) {
			if err := sh.gh.ReplyToThread(ctx, t.ID, truncate(body, replyTextMax)); err != nil {
				if !fail(err) {
					return p
				}
				continue
			}
			sent.Replied = append(sent.Replied, t.ID)
		}
		if !t.Resolve || slices.Contains(sent.Cut, t.ID) {
			continue // a thread that the prompt held in part goes back on a later try
		}
		if err := sh.gh.ResolveThread(ctx, t.ID); err != nil {
			if !fail(err) {
				return p
			}
			continue
		}
		p.resolved = append(p.resolved, t.ID)
	}
	switch comment := strings.TrimSpace(rr.Comment); {
	case comment == "" || sent.Commented:
	case !sent.Comment:
		p.left++
	default:
		if err := sh.gh.CommentPR(ctx, repo, number, truncate(comment, replyTextMax)); err != nil {
			if !fail(err) {
				return p
			}
		} else {
			sent.Commented = true
		}
	}
	p.replies, p.comment = len(sent.Replied), sent.Commented
	return p
}

// summary says what Loam posted on the PR with the number, such as "Posted
// 2 review replies and a comment on #12, and resolved 1 thread".
func (p posted) summary(number int) string {
	var what []string
	if p.replies > 0 {
		what = append(what, count(p.replies, "review reply"))
	}
	if p.comment {
		what = append(what, "a comment")
	}
	detail := fmt.Sprintf("Loam posted no review replies on #%d", number)
	if len(what) > 0 {
		detail = fmt.Sprintf("Posted %s on #%d", joinAnd(what), number)
	}
	if n := len(p.resolved); n > 0 {
		detail += fmt.Sprintf(", and resolved %s", count(n, "thread"))
	}
	switch {
	case p.left == 1:
		detail += ". Loam left out 1 reply that is not for what it sent"
	case p.left > 1:
		detail += fmt.Sprintf(". Loam left out %d replies that are not for what it sent", p.left)
	}
	return detail
}
