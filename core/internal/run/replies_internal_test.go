package run

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/github"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/GregorMcC/loam/core/internal/testutil"
)

// writeFile writes text to path, and makes its folder.
func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TAS-175: the replies file is below the git folder of the worktree, where git never commits it. A worktree whose
// .git file points out of the git folder of its repo has no replies file, because Loam reads and removes it.
func TestRepliesPathIsInTheGitFolderOfTheWorktree(t *testing.T) {
	testutil.GitEnv(t)
	repo, _ := testutil.GitRepo(t)
	folder := filepath.Join(filepath.Dir(repo), "say-hi")
	testutil.Git(t, repo, "worktree", "add", "-q", "-b", "say-hi", folder)
	dir, err := repliesDir(context.Background(), folder, repo)
	if want := filepath.Join(repo, ".git", "worktrees", "say-hi"); err != nil || dir != want {
		t.Fatalf("%q, %v, want %q", dir, err, want)
	}
	if path := repliesPath(dir); path != filepath.Join(dir, "loam", "review-replies.json") {
		t.Fatalf("path %q", path)
	}
	if dir, err := repliesDir(context.Background(), repo, repo); err != nil || dir != filepath.Join(repo, ".git") {
		t.Fatalf("the repo: %q, %v", dir, err)
	}
	other, _ := testutil.GitRepo(t)
	writeFile(t, filepath.Join(folder, ".git"), "gitdir: "+filepath.Join(other, ".git")+"\n")
	if _, err := repliesDir(context.Background(), folder, repo); err == nil || !strings.Contains(err.Error(), "is not in the git folder") {
		t.Fatalf("a worktree that points out of the repo: %v", err)
	}
}

func TestReadRepliesTakesTheFileAsUntrusted(t *testing.T) {
	dir := t.TempDir()
	path := repliesPath(dir)
	if _, err := readReplies(dir); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("no file: %v", err)
	}
	writeFile(t, path, `{"threads": [{"id": "T1", "body": "Done.", "resolve": true}], "comment": "Stays.", "pr": 9}`)
	if rr, err := readReplies(dir); err != nil || len(rr.Threads) != 1 || rr.Threads[0] != (threadReply{"T1", "Done.", true}) || rr.Comment != "Stays." {
		t.Fatalf("%+v, %v", rr, err)
	}
	many, err := json.Marshal(reviewReplies{Threads: make([]threadReply, repliesMax+1)})
	if err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct{ text, want string }{
		"not JSON":     {"Done, all of it.", "not JSON in the format of the prompt"},
		"another form": {`{"threads": {"T1": "Done."}}`, "not JSON in the format of the prompt"},
		"too large":    {`{"comment": "` + strings.Repeat("a", repliesFileMax) + `"}`, "more than 1048576 bytes"},
		"too many":     {string(many), "it has 201 thread replies, and the most is 200"},
	} {
		writeFile(t, path, c.text)
		if _, err := readReplies(dir); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// A link can point at a file that the session cannot read, such as a key. Loam reads neither the link nor a
	// folder that is a link.
	secret := filepath.Join(t.TempDir(), "secret.json")
	writeFile(t, secret, `{"comment": "the key"}`)
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, path); err != nil {
		t.Fatal(err)
	}
	if _, err := readReplies(dir); err == nil || !strings.Contains(err.Error(), "it is not a file") {
		t.Fatalf("a link: %v", err)
	}
	if err := os.RemoveAll(filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(secret, filepath.Join(filepath.Dir(secret), repliesName)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(secret), filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	if _, err := readReplies(dir); err == nil || errors.Is(err, fs.ErrNotExist) || !strings.Contains(err.Error(), "escapes") {
		t.Fatalf("a linked folder: %v", err)
	}
}

// Loam clears the file before it sends a review, and leaves a folder for the session. A folder that is a link loses
// the link, not what the link points to.
func TestClearRepliesRemovesTheFileAndNoFileThatALinkPointsTo(t *testing.T) {
	dir := t.TempDir()
	path := repliesPath(dir)
	if err := clearReplies(dir); err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(filepath.Dir(path)); err != nil || !fi.IsDir() {
		t.Fatalf("no folder: %v", err)
	}
	writeFile(t, path, "{}")
	if err := clearReplies(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the file stays: %v", err)
	}
	elsewhere := filepath.Join(t.TempDir(), repliesName)
	writeFile(t, elsewhere, "{}")
	if err := os.Remove(filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(elsewhere), filepath.Dir(path)); err != nil {
		t.Fatal(err)
	}
	if err := clearReplies(dir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(elsewhere); err != nil {
		t.Fatalf("Loam removed a file through a link: %v", err)
	}
	if fi, err := os.Lstat(filepath.Dir(path)); err != nil || !fi.IsDir() {
		t.Fatalf("the folder is not a folder: %v", err)
	}
}

// Loam posts only to the threads that it sent, once each, and posts the comment only for a review that it sent. It
// does not resolve a thread that the prompt held in part, and it cuts a long reply.
func TestPostPostsOnlyWhatLoamSent(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{}`)
	gh, err := github.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	sh := shipper{gh: gh}
	widgets := github.Repo{Owner: "example", Name: "widgets"}
	sent := &store.RunReviewReplies{PR: 7, Threads: []string{"T1", "T2", "T3", "T6"}, Cut: []string{"T2"}}
	long := strings.Repeat("a", replyTextMax+10)
	rr := reviewReplies{Threads: []threadReply{
		{ID: "T1", Body: "Fixed.", Resolve: true},
		{ID: "T2", Body: "Part of it.", Resolve: true},
		{ID: "T3", Body: long},
		{ID: "T1", Body: "Again.", Resolve: true},
		{ID: "T9", Body: "Not sent.", Resolve: true},
		{ID: "T4", Body: "  ", Resolve: true},
		{ID: "T5", Body: ""},
		{ID: "T6", Resolve: true},
	}, Comment: "No review asked for this."}
	p := sh.post(context.Background(), widgets, 7, sent, rr)
	// T6 has no text: Loam resolves it with no reply.
	if p.replies != 3 || !slices.Equal(p.resolved, []string{"T1", "T6"}) || p.comment || p.left != 4 || len(p.failed) != 0 || p.retry != nil {
		t.Fatalf("%+v", p)
	}
	if !slices.Equal(sent.Replied, []string{"T1", "T2", "T3"}) {
		t.Fatalf("replied %q", sent.Replied)
	}
	if got := p.summary(7); got != "Posted 3 review replies on #7, and resolved 2 threads. Loam left out 4 replies that are not for what it sent" {
		t.Fatalf("summary %q", got)
	}
	var posts struct {
		ThreadReplies map[string][]string `json:"thread_replies"`
		Resolved      []string            `json:"resolved"`
	}
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &posts)
	}
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(posts.ThreadReplies["T1"], []string{"Fixed."}) || len(posts.ThreadReplies["T9"]) != 0 ||
		!slices.Equal(posts.Resolved, []string{"T1", "T6"}) || len(posts.ThreadReplies["T6"]) != 0 {
		t.Fatalf("%+v", posts)
	}
	if got := posts.ThreadReplies["T3"]; len(got) != 1 || len([]rune(got[0])) != replyTextMax || !strings.HasSuffix(got[0], "…") {
		t.Fatalf("long reply %d characters", len([]rune(got[0])))
	}
	// With a review sent, the comment goes on the PR.
	withReview := &store.RunReviewReplies{PR: 7, Threads: []string{"T1"}, Comment: true}
	if p := sh.post(context.Background(), widgets, 7, withReview, reviewReplies{Comment: "The name stays."}); !p.comment || p.summary(7) != "Posted a comment on #7" {
		t.Fatalf("%+v", p)
	}
	if p := (posted{}); p.summary(7) != "Loam posted no review replies on #7" {
		t.Fatalf("%q", p.summary(7))
	}
}

// With no network, Loam stops at the first post that fails, and records what it posted. The next try posts the
// rest, and no reply twice.
func TestPostStopsWhenGitHubIsOutOfReachAndPostsTheRestLater(t *testing.T) {
	testutil.Home(t)
	testutil.FakeGH(t, `{}`)
	gh, err := github.NewClient()
	if err != nil {
		t.Fatal(err)
	}
	sh := shipper{gh: gh}
	widgets := github.Repo{Owner: "example", Name: "widgets"}
	sent := &store.RunReviewReplies{PR: 7, Threads: []string{"T1", "T2"}, Comment: true}
	rr := reviewReplies{Threads: []threadReply{{ID: "T1", Body: "Fixed.", Resolve: true}, {ID: "T2", Body: "Stays."}}, Comment: "The name stays."}
	t.Setenv("LOAM_FAKE_GH_FAIL", "offline")
	t.Setenv("LOAM_FAKE_GH_FAIL_CALL", "2") // the resolve of T1
	p := sh.post(context.Background(), widgets, 7, sent, rr)
	if !errors.Is(p.retry, github.ErrOffline) || !slices.Equal(sent.Replied, []string{"T1"}) || sent.Commented {
		t.Fatalf("%+v, sent %+v", p, sent)
	}
	t.Setenv("LOAM_FAKE_GH_FAIL", "")
	p = sh.post(context.Background(), widgets, 7, sent, rr)
	if p.retry != nil || p.replies != 2 || !slices.Equal(p.resolved, []string{"T1"}) || !p.comment || len(p.failed) != 0 {
		t.Fatalf("%+v", p)
	}
	var posts struct {
		ThreadReplies map[string][]string `json:"thread_replies"`
		PRComments    map[string][]string `json:"pr_comments"`
	}
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &posts)
	}
	if err != nil {
		t.Fatal(err)
	}
	if len(posts.ThreadReplies["T1"]) != 1 || len(posts.ThreadReplies["T2"]) != 1 || len(posts.PRComments["7"]) != 1 {
		t.Fatalf("%+v", posts)
	}
}
