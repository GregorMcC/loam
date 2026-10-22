// Command fakegh stands in for `gh` in tests. It answers `gh api graphql
// --input -` from a GitHub state in the JSON file named in
// LOAM_FAKE_GH_STATE, and appends each call as one JSON line to the file
// named in LOAM_FAKE_GH_LOG.
//
// The state file holds:
//
//   - "refs": the branches that are on GitHub.
//   - "pulls": pull request nodes for the first query. A branch gets each
//     node whose headRefName is the branch, in the order of the file.
//   - "details": pull request nodes for the second query, keyed by number.
//
// The fake reads the query variables as Loam names them: h<i> is a branch
// in the first query, and n<i> is a PR number in the second query.
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
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

type state struct {
	Refs    []string                   `json:"refs"`
	Pulls   []map[string]any           `json:"pulls"`
	Details map[string]json.RawMessage `json:"details"`
}

func main() {
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
	call := logCall(req.Variables)

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

	var st state
	b, err := os.ReadFile(os.Getenv("LOAM_FAKE_GH_STATE"))
	if err == nil {
		err = json.Unmarshal(b, &st)
	}
	if err != nil {
		fail(2, "fakegh: state: "+err.Error())
	}
	repo := map[string]any{}
	for name, v := range req.Variables {
		i, isBranch := strings.CutPrefix(name, "h")
		if _, err := strconv.Atoi(i); !isBranch || err != nil || req.Variables["n"+i] != nil {
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
	for name, v := range req.Variables {
		if i, ok := strings.CutPrefix(name, "n"); ok {
			number, _ := v.(float64)
			repo["p"+i] = st.Details[strconv.Itoa(int(number))]
		}
	}
	out, _ := json.Marshal(map[string]any{"data": map[string]any{"repository": repo}})
	fmt.Println(string(out))
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
// pkg/cmd/api/api.go of the gh source.)
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
func logCall(vars map[string]any) int {
	path := os.Getenv("LOAM_FAKE_GH_LOG")
	if path == "" {
		return 0
	}
	line, _ := json.Marshal(map[string]any{"args": os.Args[1:], "variables": vars})
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
