// Command fakegh stands in for `gh` in tests. It answers from a GitHub
// state in the JSON file named in LOAM_FAKE_GH_STATE, and appends each call
// as one JSON line to the file named in LOAM_FAKE_GH_LOG.
//
// The state file holds:
//
//   - "refs": the branches that are on GitHub.
//   - "heads": the commit at the head of a branch on GitHub, by branch. A
//     branch that is not here has the head of its first PR.
//   - "pulls": pull request nodes for the first query. A branch gets each
//     node whose headRefName is the branch, in the order of the file.
//   - "details": pull request nodes for the second query, keyed by number.
//   - "repository": fields of the repo, such as the merge methods it allows.
//   - "merge_queue": true when the base branch of each PR has a merge queue.
//   - "merge_lag": true when GitHub merges a PR, and the queries do not show
//     the merge yet.
//   - "auto_merges_clean": true when gh merges a PR at once with --auto when
//     its merge state is CLEAN, as gh does.
//   - "delete_refusals": the message of GitHub for a delete of a branch that
//     GitHub refuses with HTTP 422, such as for a protected branch or a
//     ruleset, by branch. The branch stays.
//   - "rerun_refusals": the message of GitHub for a run that GitHub does not
//     run again, by run ID.
//   - "issues": the open issues of the repo, as gh issue list --json prints
//     them.
//   - "login": the login that gh api user --jq .login prints.
//   - "merge_refusal": the message of GitHub for a merge that it refuses, such
//     as "Pull request is not mergeable". The PR stays open. A state file with no
//     "merge_refusal" merges again, so a test can fail a merge and then retry it.
//   - "logs": the log of the failed jobs of a run, as gh run view --log-failed
//     prints it, by run ID.
//   - "create_refusal": the message of GitHub for a gh pr create that it
//     refuses. No PR opens.
//
// The fake answers these commands:
//
//   - gh api graphql --input -: a query, from the state. It reads the query
//     variables as Loam names them: h<i> is a branch in the first query, n<i>
//     is a PR number in the second query, and number is the PR of the merge
//     settings.
//   - gh api user --jq .login: prints "login".
//   - gh api repos/<owner>/<repo>/git/ref/heads/<branch>: the head of a branch.
//   - gh api --method DELETE repos/<owner>/<repo>/git/refs/heads/<branch>:
//     removes the branch from "refs". GitHub gives HTTP 422 in two cases: the
//     reference does not exist, or GitHub refuses the delete
//     ("delete_refusals").
//   - gh pr merge <number>: merges the PR. With a merge queue, it puts the PR
//     in the queue. With --auto, the PR stays open, unless "auto_merges_clean"
//     merges it. --match-head-commit must be the PR head.
//   - gh pr update-branch <number>: a PR that is behind its base is clean.
//   - gh pr view <number> --json state,number: prints the state and the number
//     of the PR of "pulls" with that number, or fails as gh does.
//   - gh issue list: prints "issues".
//   - gh issue view <url>: prints the title and the body of the issue of
//     "issues" with that URL, or fails as gh does for a missing issue.
//   - gh run rerun <id> --failed: does nothing, or fails as "rerun_refusals"
//     says.
//   - gh pr create --head <branch>: adds an open PR to "pulls", with the next
//     free number, and prints its URL. The PR keeps its "title" and its "body".
//   - gh run view <id> --log-failed: prints the log of "logs".
//
// LOAM_FAKE_GH_FAIL makes each call fail as gh does, with the exit code and
// the text that gh prints (see [failures]). "hang" waits for a minute, as a
// call with no network can. With LOAM_FAKE_GH_FAIL_CALL set to a number n,
// only call n fails, counted from 1 in the log.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"time"
)

type state struct {
	Refs           []string                   `json:"refs"`
	Heads          map[string]string          `json:"heads,omitempty"`
	Pulls          []map[string]any           `json:"pulls"`
	Details        map[string]json.RawMessage `json:"details"`
	Repository     map[string]any             `json:"repository,omitempty"`
	MergeQueue     bool                       `json:"merge_queue,omitempty"`
	MergeLag       bool                       `json:"merge_lag,omitempty"`
	AutoMergeClean bool                       `json:"auto_merges_clean,omitempty"`
	DeleteRefusals map[string]string          `json:"delete_refusals,omitempty"`
	RerunRefusals  map[string]string          `json:"rerun_refusals,omitempty"`
	MergeRefusal   string                     `json:"merge_refusal,omitempty"`
	CreateRefusal  string                     `json:"create_refusal,omitempty"`
	Issues         []map[string]any           `json:"issues,omitempty"`
	Login          string                     `json:"login,omitempty"`
	Logs           map[string]string          `json:"logs,omitempty"`
}

func main() {
	args := os.Args[1:]
	var vars map[string]any
	isQuery := slices.Equal(args, []string{"api", "graphql", "--hostname", "github.com", "--input", "-"})
	if isQuery {
		body, err := io.ReadAll(os.Stdin)
		if err != nil {
			fail(2, "fakegh: "+err.Error())
		}
		var req struct {
			Variables map[string]any `json:"variables"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			fail(2, "fakegh: the request body is not JSON: "+err.Error())
		}
		vars = req.Variables
	}
	call := logCall(args, vars)

	if mode := os.Getenv("LOAM_FAKE_GH_FAIL"); mode != "" && failsNow(call) {
		if mode == "hang" {
			time.Sleep(time.Minute)
		} else if f, ok := failures[mode]; ok {
			fmt.Print(f.stdout)
			fail(f.code, f.stderr)
		} else {
			fail(2, "fakegh: unknown LOAM_FAKE_GH_FAIL "+mode)
		}
	}

	st := readState()
	switch {
	case isQuery:
		query(st, vars)
	case len(args) > 1 && args[0] == "api":
		rest(st, args[1:])
	case len(args) > 2 && args[0] == "pr" && args[1] == "merge":
		merge(st, args[2:])
	case len(args) > 2 && args[0] == "pr" && args[1] == "view":
		view(st, args[2])
	case len(args) > 2 && args[0] == "pr" && args[1] == "update-branch":
		updateBranch(st, args[2])
	case len(args) > 1 && args[0] == "issue" && args[1] == "list":
		issues(st)
	case len(args) > 2 && args[0] == "issue" && args[1] == "view":
		issue(st, args[2])
	case len(args) > 2 && args[0] == "run" && args[1] == "rerun":
		rerun(st, args[2])
	case len(args) > 1 && args[0] == "pr" && args[1] == "create":
		create(st, args[2:])
	case len(args) > 2 && args[0] == "run" && args[1] == "view":
		fmt.Print(st.Logs[args[2]])
	default:
		fail(2, "fakegh: unknown command "+strings.Join(args, " "))
	}
}

func readState() *state {
	var st state
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &st)
	}
	if err != nil {
		fail(2, "fakegh: state: "+err.Error())
	}
	return &st
}

// write saves the state, so the next call sees what this call changed.
func (st *state) write() {
	b, err := json.MarshalIndent(st, "", "  ")
	if err == nil {
		err = os.WriteFile(os.Getenv("LOAM_FAKE_GH_STATE"), b, 0o644)
	}
	if err != nil {
		fail(2, "fakegh: state: "+err.Error())
	}
}

// query answers a GraphQL query.
func query(st *state, vars map[string]any) {
	repo := map[string]any{}
	for k, v := range st.Repository {
		repo[k] = v
	}
	for name, v := range vars {
		i, isBranch := strings.CutPrefix(name, "h")
		if _, err := strconv.Atoi(i); !isBranch || err != nil || vars["n"+i] != nil {
			continue
		}
		branch, _ := v.(string)
		nodes := []map[string]any{}
		for _, p := range st.Pulls {
			if p["headRefName"] == branch {
				nodes = append(nodes, p)
			}
		}
		repo["pr"+i] = map[string]any{"nodes": nodes}
		repo["ref"+i] = nil
		if slices.Contains(st.Refs, branch) {
			repo["ref"+i] = map[string]any{"name": branch}
		}
	}
	for name, v := range vars {
		i, isPR := strings.CutPrefix(name, "n")
		if _, err := strconv.Atoi(i); !isPR || err != nil {
			continue
		}
		number, _ := v.(float64)
		repo["p"+i] = st.Details[strconv.Itoa(int(number))]
	}
	if _, ok := vars["number"]; ok {
		repo["pullRequest"] = map[string]any{"isMergeQueueEnabled": st.MergeQueue}
	}
	out, _ := json.Marshal(map[string]any{"data": map[string]any{"repository": repo}})
	fmt.Println(string(out))
}

// rest answers gh api for the ref of a branch: a read, or a delete.
func rest(st *state, args []string) {
	if slices.Contains(args, "user") {
		fmt.Println(st.Login)
		return
	}
	method, path := "GET", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--hostname":
			i++
		case "--method":
			i++
			method = args[i]
		default:
			path = args[i]
		}
	}
	_, escaped, ok := strings.Cut(path, "/heads/")
	branch, err := url.PathUnescape(escaped)
	if !ok || err != nil {
		fail(2, "fakegh: unknown api path "+path)
	}
	if !slices.Contains(st.Refs, branch) {
		if method == "DELETE" {
			fail(1, "gh: Reference does not exist (HTTP 422)")
		}
		fail(1, "gh: Not Found (HTTP 404)")
	}
	if msg, ok := st.DeleteRefusals[branch]; ok && method == "DELETE" {
		fail(1, "gh: "+msg+" (HTTP 422)")
	}
	if method == "DELETE" {
		st.Refs = slices.DeleteFunc(st.Refs, func(r string) bool { return r == branch })
		st.write()
		return
	}
	out, _ := json.Marshal(map[string]any{"ref": "refs/heads/" + branch, "object": map[string]any{"sha": st.head(branch)}})
	fmt.Println(string(out))
}

// head returns the commit at the head of a branch on GitHub.
func (st *state) head(branch string) string {
	if h, ok := st.Heads[branch]; ok {
		return h
	}
	for _, p := range st.Pulls {
		if p["headRefName"] == branch {
			h, _ := p["headRefOid"].(string)
			return h
		}
	}
	return ""
}

// pull returns the first PR with the number in the argument.
func (st *state) pull(arg string) map[string]any {
	for _, p := range st.Pulls {
		if n, _ := p["number"].(float64); strconv.Itoa(int(n)) == arg {
			return p
		}
	}
	fail(1, "GraphQL: Could not resolve to a PullRequest with the number of "+arg+". (repository.pullRequest)")
	return nil
}

// merge merges a PR as gh pr merge does.
func merge(st *state, args []string) {
	p := st.pull(args[0])
	auto, method := false, "merge"
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--auto":
			auto = true
		case "--squash", "--merge", "--rebase":
			method = strings.TrimPrefix(args[i], "--")
		case "--match-head-commit":
			i++
			if args[i] != p["headRefOid"] {
				fail(1, "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)")
			}
		case "--repo":
			i++
		}
	}
	if st.MergeRefusal != "" {
		fail(1, "GraphQL: "+st.MergeRefusal+" (mergePullRequest)")
	}
	switch {
	case st.MergeQueue:
		p["isInMergeQueue"] = true
		p["mergeQueueEntry"] = map[string]any{"position": 1}
		fmt.Printf("✓ Pull request example/widgets#%s will be added to the merge queue for main when ready\n", args[0])
	case auto && !(st.AutoMergeClean && p["mergeStateStatus"] == "CLEAN"):
		fmt.Printf("✓ Pull request example/widgets#%s will be automatically merged via %s when all requirements are met\n", args[0], method)
	case st.MergeLag:
		fmt.Printf("✓ Merged pull request example/widgets#%s\n", args[0])
	default:
		now := time.Now().UTC().Format(time.RFC3339)
		p["state"], p["mergedAt"], p["closedAt"] = "MERGED", now, now
		fmt.Printf("✓ Merged pull request example/widgets#%s\n", args[0])
	}
	st.write()
}

// view prints the state and the number of a PR, as gh pr view --json
// state,number does.
func view(st *state, number string) {
	p := st.pull(number)
	b, err := json.Marshal(map[string]any{"number": p["number"], "state": p["state"]})
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	fmt.Println(string(b))
}

// rerun runs the failed jobs of a run again, as gh run rerun --failed does.
// gh prints the HTTP error of GitHub with the URL of the request.
func rerun(st *state, id string) {
	if msg, ok := st.RerunRefusals[id]; ok {
		fail(1, fmt.Sprintf("failed to rerun: HTTP 403: %s (https://api.github.com/repos/example/widgets/actions/runs/%s/rerun-failed-jobs)", msg, id))
	}
}

// create opens a PR, as gh pr create does: it prints the URL of the PR.
func create(st *state, args []string) {
	var head, base, title, body string
	for i := 0; i+1 < len(args); i++ {
		switch args[i] {
		case "--body-file":
			if args[i+1] == "-" {
				b, _ := io.ReadAll(os.Stdin)
				body = string(b)
			}
		case "--head":
			head = args[i+1]
		case "--base":
			base = args[i+1]
		case "--title":
			title = args[i+1]
		}
	}
	if head == "" {
		fail(1, "fakegh: pr create needs --head")
	}
	if st.CreateRefusal != "" {
		fail(1, "pull request create failed: GraphQL: "+st.CreateRefusal+" (createPullRequest)")
	}
	number := 1
	for _, p := range st.Pulls {
		if n, ok := p["number"].(float64); ok && int(n) >= number {
			number = int(n) + 1
		}
	}
	url := fmt.Sprintf("https://github.com/example/widgets/pull/%d", number)
	st.Pulls = append(st.Pulls, map[string]any{
		"number": number, "title": title, "body": body, "url": url, "state": "OPEN", "headRefName": head,
		"baseRefName": base, "headRefOid": st.head(head), "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN",
	})
	if !slices.Contains(st.Refs, head) {
		st.Refs = append(st.Refs, head)
	}
	st.write()
	fmt.Println(url)
}

// issues prints the open issues, as gh issue list --json does.
func issues(st *state) {
	list := st.Issues
	if list == nil {
		list = []map[string]any{}
	}
	b, err := json.Marshal(list)
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	fmt.Println(string(b))
}

// issue prints the title and the body of one issue, as gh issue view --json
// title,body does.
func issue(st *state, url string) {
	for _, i := range st.Issues {
		if i["url"] == url {
			b, err := json.Marshal(map[string]any{"title": i["title"], "body": i["body"]})
			if err != nil {
				fail(2, "fakegh: "+err.Error())
			}
			fmt.Println(string(b))
			return
		}
	}
	fail(1, "GraphQL: Could not resolve to an issue or pull request with the number of "+path.Base(url)+". (repository.issue)")
}

// updateBranch brings a PR up to date with its base, as gh pr update-branch does.
func updateBranch(st *state, arg string) {
	p := st.pull(arg)
	if p["mergeStateStatus"] == "BEHIND" {
		p["mergeStateStatus"] = "CLEAN"
	}
	st.write()
	fmt.Println("✓ PR branch updated")
}

// failure is how gh fails: its exit code, stdout, and stderr.
type failure struct {
	code           int
	stdout, stderr string
}

// failures holds the text that gh prints for each failure. gh api prints
// "gh: " and the message of GitHub. A message of an HTTP error ends with the
// HTTP status. A GraphQL error comes with HTTP 200, so its message has no
// status, and gh prints the answer on stdout too. With an SSO header, gh adds
// a line to authorize. (See processResponse and parseErrorResponse in
// pkg/cmd/api/api.go of the gh source.) gh pr merge prints why GitHub does
// not merge, and a hint for its own flags on the next line.
var failures = map[string]failure{
	"signed_out": {4, "", "To get started with GitHub CLI, please run:  gh auth login\n" +
		"Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."},
	"bad_credentials":      {1, "", "gh: Bad credentials (HTTP 401)"},
	"rate_limited":         graphQLError("RATE_LIMITED", "API rate limit exceeded for user ID 1."),
	"secondary_rate_limit": {1, "", "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)"},
	"forbidden":            {1, "", "gh: Resource not accessible by personal access token (HTTP 403)"},
	"not_found":            {1, "", "gh: Not Found (HTTP 404)"},
	"no_repo":              graphQLError("NOT_FOUND", "Could not resolve to a Repository with the name 'example/widgets'."),
	"saml": withSSOLine(graphQLError("FORBIDDEN",
		"Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization.")),
	"sso": graphQLError("FORBIDDEN",
		"The 'example' organization has enabled or enforced SAML SSO. To access this repository, you must re-authorize the OAuth Application 'GitHub CLI'."),
	"offline": {1, "", "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com"},
	"not_mergeable": {1, "", "X Pull request example/widgets#15 is not mergeable: the base branch policy prohibits the merge.\n" +
		"To have the pull request merged after all the requirements have been met, add the `--auto` flag."},
	"reference_missing": {1, "", "gh: Reference does not exist (HTTP 422)"},
}

func graphQLError(kind, msg string) failure {
	body, _ := json.Marshal(map[string]any{"data": nil, "errors": []map[string]string{{"type": kind, "message": msg}}})
	return failure{1, string(body) + "\n", "gh: " + msg}
}

func withSSOLine(f failure) failure {
	f.stderr += "\nAuthorize in your web browser: https://github.com/orgs/example/sso?authorization_request=EXAMPLE"
	return f
}

// failsNow reports whether this call fails: every call, or only the one
// that LOAM_FAKE_GH_FAIL_CALL names.
func failsNow(call int) bool {
	n := os.Getenv("LOAM_FAKE_GH_FAIL_CALL")
	if n == "" {
		return true
	}
	want, err := strconv.Atoi(n)
	if err != nil {
		fail(2, "fakegh: LOAM_FAKE_GH_FAIL_CALL is not a number")
	}
	return call == want
}

// logCall appends the arguments and the query variables of this call to the
// log. It returns the number of this call, from 1, or 0 with no log.
func logCall(args []string, vars map[string]any) int {
	path := os.Getenv("LOAM_FAKE_GH_LOG")
	if path == "" {
		return 0
	}
	line, _ := json.Marshal(map[string]any{"args": args, "variables": vars})
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	defer f.Close()
	fmt.Fprintln(f, string(line))
	b, err := os.ReadFile(path)
	if err != nil {
		fail(2, "fakegh: "+err.Error())
	}
	return strings.Count(string(b), "\n")
}

func fail(code int, msg string) {
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(code)
}
