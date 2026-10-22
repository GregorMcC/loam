# The loam contract

The app talks to the core through the `loam` command. This file is the contract: the exit codes, the JSON error, the global flags, and the `--json` output of each command.

The contract version is 1. Run `loam version --json` to read it. The version goes up only when a change makes the output unreadable for the app. A new field does not raise it. The app must ignore fields it does not know.

Later tickets add their commands to this file.

The folder `contract/` at the repo root holds a fixture and a JSON Schema for each command. A test in `core/internal/contract/` fails when this file, the schemas, the fixtures, and the real output disagree. A change to this file needs a change to `contract/`. See `contract/README.md`.

## Global flags

| Flag | Meaning |
| :- | :- |
| `--json` | Print machine-readable JSON. A failure prints the JSON error. |
| `--actor app` | Record the actor of a write as you in the app. Without it, the actor is you in the CLI. Any other value exits with code 2. |

Every write also takes `--expect <item>=<version>`, once for each item the caller read. Items are `name`, `what`, `why`, `where`, `link:<id>`, `repo:<id>`, and `worktree:<id>`. The versions are in `versions` of a plot, and in `version` of each link, repo, and worktree. Without `--expect`, a write goes over the latest value.

## Exit codes

| Code | Kind | Meaning |
| -: | :- | :- |
| 0 | | Success |
| 1 | `error` | Any error with no code of its own |
| 2 | `invalid` | Bad flag, argument, or value |
| 10 | `stale` | A write used a version that is out of date. Nothing was written. |
| 11 | `undo_clash` | An undo meets a later change to the same item (ticket 16) |
| 12 | `link_path_missing` | A local link points at a path that does not exist. `loam open` returns it (ticket 34). |
| 13 | `contract_mismatch` | The contract version is not the one the caller expects. The app reports it. The core does not return it today. |
| 14 | `unknown_plot` | No plot matches the argument |
| 15 | `ambiguous` | The argument matches more than one plot, or more than one link label |
| 16 | `not_ready` | A check blocks the land of a worktree. `loam worktree land` returns it (ticket 111). |
| 17 | `gh_unavailable` | gh is missing or signed out, or the origin of the repo is not on GitHub. `loam worktree land`, `rerun`, and `update` return it (ticket 111). |

The table is in `core/internal/cli/exitcode.go`. A code never changes meaning.

## The JSON error

With `--json`, a failed command prints one JSON document on stdout and nothing on stderr. The exit code is the same as without `--json`. Warnings go to stderr as text, also with `--json`.

```json
{
  "error": {
    "kind": "stale",
    "exit_code": 10,
    "message": "stale write: what changed since you read it; what is now at version 41: \"current text\"",
    "details": {}
  }
}
```

- `kind` and `exit_code` are stable. `message` is for a person to read.
- `details` is present only for some kinds.

Details of `stale`:

```json
{
  "plot_id": "k3v9q2mxa7",
  "items": [
    {
      "item": "what",
      "expected": 40,
      "current": 41,
      "exists": true,
      "value": "current text"
    }
  ]
}
```

- `item` is the stale item.
- `exists` is false when the item is gone. A stale link, repo, or worktree has `link`, `repo`, or `worktree` with the current object. A stale `name`, `what`, `why`, or `where` has `value`.

Details of `undo_clash`:

```json
{
  "change_id": 41,
  "plot_id": "k3v9q2mxa7",
  "later_changes": [
    { "id": 43, "plot_id": "k3v9q2mxa7", "at": "2026-10-02T09:05:00Z",
      "actor": { "kind": "session", "session_id": "...", "loam_started": true },
      "entries": [{ "item": "where", "field": "value", "old": "one", "new": "two" }], "undo_of": null }
  ],
  "undo_would_write": [{ "item": "where", "field": "value", "old": "two", "new": "" }]
}
```

- `later_changes` are the later changes that touched the same items, oldest first. Each is a change object as in `loam changes`.
- `undo_would_write` shows each field that the undo would set. `old` is the current value and `new` is the value the undo writes. A null means the item does not exist.

Details of `not_ready`:

```json
{ "checks": [{ "name": "conflicts", "state": "conflicting", "blocks": true }] }
```

- `checks` lists each check that blocks the land, in the order of the land result. See [Land, rerun, and update](#land-rerun-and-update).

## Commands

### `loam version --json`

```json
{ "version": "v0.1.0", "contract_version": 1 }
```

### `loam list --json`

An array in the stored plot order. It is `[]` when no plot exists. Archived plots are not in it. `loam list --archived --json` has the same shape and holds only the archived plots, in the same order. See "Archive and delete".

```json
[{ "id": "k3v9q2mxa7", "name": "Loam", "what": "...", "created_at": "2026-10-02T09:00:00Z", "archived": false }]
```

### Plot object

`show`, `new`, `edit`, `set`, `archive`, and `unarchive` print a plot with `--json`. Each plot of `loam export` has the same shape. `loam export` holds archived plots too.

```json
{
  "id": "k3v9q2mxa7",
  "name": "Loam",
  "what": "...",
  "why": "...",
  "where_it_stands": "...",
  "created_at": "2026-10-02T09:00:00Z",
  "archived": false,
  "links": [{ "id": "...", "label": "...", "target": "...", "note": "", "position": 0, "version": 12, "kind": "url" }],
  "repos": [{ "id": "...", "path": "/abs/path", "note": "", "main": true, "version": 12, "setup": "npm ci", "copy": [".env"] }],
  "versions": { "name": 12, "what": 12, "why": 12, "where": 40, "link:<id>": 12, "repo:<id>": 12 },
  "revision": 40
}
```

- `setup` and `copy` in a repo are the worktree settings of the repo path. They are left out when empty. See "Worktrees".
- `versions` maps each item to the ID of the change that last set it. Pass these as `--expect`. Each worktree of the plot is an item, `worktree:<id>`. Its version is 0 until a change sets its goal.
- `revision` is the highest change ID of the plot.
- `archived` is always present. It is not a versioned item, so it is not in `versions`.
- Each link has `kind`. A `path` or `vault` link also has `exists`. See "Link kinds".

| Command | Output |
| :- | :- |
| `loam show <plot> --json` | The plot object |
| `loam new <name> --json` | The new plot object. It skips the editor. |
| `loam set <plot> <field> <text\|-> [--expect ...] --json` | The plot object after the write. Fields: `name`, `what`, `why`, `where-it-stands`. |
| `loam edit <plot> [--expect ...] --json` | The plot object. It still opens `$EDITOR`, so the app does not use it. |

### Link kinds

`kind` of a link comes from its target. The core works it out each time it prints a plot. It is not stored.

| Kind | Target |
| :- | :- |
| `notion` | A URL on `notion.so` or `notion.site`, with or without a subdomain |
| `linear` | A URL on `linear.app` |
| `github` | A URL on `github.com` |
| `url` | Any other target that is not a local path |
| `vault` | A local path in an Obsidian vault. The vault can be the path itself or a parent of it. |
| `path` | A local path that no vault holds |

- A local path starts with `/` or `~`. The core expands `~`.
- The core reads the vaults from `~/Library/Application Support/obsidian/obsidian.json` (the `vaults` map, each entry with a `path`). With nested vaults, the deepest vault that holds the path wins. A missing or unreadable file means no vaults.
- `exists` is true when the local path exists now. It is present for `path` and `vault` links only. A `vault` link to a missing path keeps its kind.
- MCP `get_plot` returns `kind` and `exists` for each link in the same way.
- The link write commands below print the link without `kind` and `exists`.

### `loam open <plot> <link> --json`

Opens a link. `<link>` is a link ID or an exact label. The command uses the macOS `open` command.

| Target | What opens |
| :- | :- |
| `notion`, `linear`, `github`, `url` | An http or https URL, in the default browser (`browser`). A URL with the scheme `mailto`, `obsidian`, `notion`, `linear`, or `slack`, in the app that handles it (`default_app`). Any other scheme is `invalid` (exit code 2), and nothing opens |
| `vault` file | Obsidian, with `obsidian://open?path=`. When no app handles `obsidian://`, the file opens in its default app. (`obsidian` or `default_app`) |
| Any folder, in a vault or not | The folder, in Finder (`finder`) |
| `path` file | The file, in its default app (`default_app`) |
| A file or a bundle that `open` would run | Revealed in Finder, not run (`finder`). This covers a file with an execute bit, a folder with `Contents/Info.plist`, and the extensions `.app`, `.command`, `.tool`, `.terminal`, `.pkg`, `.mpkg`, `.workflow`, `.action`, and `.jar` |

```json
{ "plot": "k3v9q2mxa7", "link_id": "k3v9q2mxa8", "kind": "github", "opened_with": "browser" }
```

- A local path that does not exist gives exit code 12 and the `link_path_missing` error. Nothing opens.
- A target that is not a local path and has no URL scheme is `invalid` (exit code 2). So is a URL with a scheme that is not in the table.
- If the `open` command fails, the exit code is 1.
- `loam open` is not an MCP tool.

Details of `link_path_missing`:

```json
{ "plot_id": "k3v9q2mxa7", "link_id": "k3v9q2mxa8", "path": "/abs/path/that/is/missing" }
```

### Link and repo writes

These commands print the change ID, the plot ID, and the link or repo that the change touched.

```json
{ "change_id": 41, "plot": "k3v9q2mxa7", "link": { "id": "...", "label": "...", "target": "...", "note": "", "position": 0, "version": 41 } }
```

- `change_id` is 0 when the edit changed nothing.
- A removal has no `link` or `repo`.
- `repo` has the repo object in the same way as `link`.

| Command | Output |
| :- | :- |
| `loam link add <plot> [<label>] <target> [--note]` | `change_id`, `plot`, `link` |
| `loam link edit <plot> <link> [--label] [--target] [--note]` | `change_id`, `plot`, `link` |
| `loam link rm <plot> <link>` | `change_id`, `plot` |
| `loam repo add <plot> <path> [--note] [--setup] [--copy]` | `change_id`, `plot`, `repo` |
| `loam repo edit <plot> <repo> [--note] [--setup] [--copy]` | `change_id`, `plot`, `repo` |
| `loam repo main <plot> <repo>` | `change_id`, `plot`, `repo` |
| `loam repo rm <plot> <repo> [--main <repo>]` | `change_id`, `plot` |

`loam link add` with no label, or MCP `add_link` with no `label`, takes the label from the target. A local path gives the file name with no extension, or the folder name. GitHub gives `<repo> on GitHub`, or `<repo>#<n>` for an issue or pull request. Linear gives the issue ID, Notion the page title, Obsidian the note name, and any other URL the host.

`loam repo add`, MCP `add_repo`, and MCP `create_plot` expand a leading `~`. They fail with exit code 2 (`invalid`) when the repo path does not exist or is a file. The message names the path.

`loam repo add` also adds the repo's git remote as a link, in the same change, so one undo removes both. It uses `origin`, else the first remote, as a web URL with no user name or token. It adds no link when the folder has no remote, the remote is a local path, or the plot already has a link to that URL. MCP `add_repo` and `create_plot` do the same. `repo` in the output is still the new repo.

After the add, `loam repo add` puts the checkout on the default branch of `origin`. It fetches `origin`, switches the checkout to that branch (it makes the local branch from `origin/<branch>` if needed), and fast-forwards it to `origin/<branch>`. A checkout with uncommitted changes to tracked files keeps its branch. Untracked files do not count. The add still succeeds. Loam does nothing to a repo with no commits or no `origin`, or to a linked worktree. What Loam could not do is a warning on stderr and, with `--json`, in `warnings`. MCP `add_repo` and `create_plot` do the same and return `warnings`. Every plot that holds the path shares the checkout, so the switch shows in each of them.

`loam repo rm` of the main repo needs `--main` with `--json` or with no terminal, because the command cannot ask. Without it, the command exits with code 2 (`invalid`).

`loam repo rm` fails with exit code 1 while the plot has worktrees of the repo. The same holds for MCP `remove_repo`.

`--setup` and `--copy` set the worktree settings of the repo path. `--copy` is repeatable. An empty value clears the setting. The settings are not a change: they have no change log entry and no undo, so `change_id` is 0 when only they changed. Every plot that holds the path shows the same settings.

### Worktrees

A worktree is a separate checkout of one repo of a plot, on its own branch. It lives in `<loam home>/worktrees/<plot-id>/<repo folder>-<name>/`. Making or removing one is not a change in the change log. A goal edit is a change.

```json
{
  "id": "wtreeaaaab", "plot_id": "k3v9q2mxa7", "repo": "/abs/path/of/repo", "name": "fix-login", "branch": "fix-login",
  "base": "origin/main", "path": "/abs/path/of/worktree", "setup_done": false, "created_at": "2026-10-02T09:00:00Z",
  "goal": "Fix the login form",
  "link": { "target": "https://github.com/example/widgets/issues/57", "label": "widgets#57", "key": "#57", "link_id": "" },
  "version": 0,
  "land": { "pr": 12, "method": "squash", "auto": true, "merge_queue": false, "keep_worktree": false, "keep_remote_branch": false }
}
```

- `name` is the branch name. `base` is the branch that a new branch started from. It is empty when the branch existed.
- `setup_done` is true after the setup command has succeeded in the worktree.
- `goal` is one line that says what the worktree is for. It is empty when none is set. The JSON keeps the goal as it was given. The seed and the text output show it on one line, with each control character, such as ESC, as a space.
- `link` is the link that the work started from, or null. It belongs to the worktree, not to the links of the plot, and it goes when the worktree goes. `link_id` is the ID of the plot link that it was copied from, or empty for a URL.
- `link.key` names the issue, so that a PR body can put "Fixes" and the key. `worktree new` sets the key, and the record keeps it. The seed line, the text output, and the JSON show the same key.
  - A Linear issue: the issue ID, such as `ENG-482`.
  - A GitHub issue in the repo of `origin` on github.com: `#` and the number, such as `#57`. Loam compares the owner and the repo without case.
  - A GitHub issue in another repo: `owner/repo#57`, such as `example/widgets#57`, because GitHub reads `#57` as an issue of the repo of the PR. A repo with no `origin` on github.com always gets this form.
  - Any other link: empty.
- `version` is the ID of the change that last set the goal, or 0 when no change has set it.
- `land` is a land that waits for GitHub to merge the PR: an auto merge, or a merge queue. It is also a land that GitHub may have when Loam cannot see the merge. It holds the options of `loam worktree land`, and a later land applies its keeps. `method` is empty with a merge queue. `land` is left out when no land waits.

| Command | Output |
| :- | :- |
| `loam worktree new <plot> <repo> <name> [--base <branch>] [--goal <text>] [--link <link-id or URL>]` | `{ "worktree": {...}, "copied": ["relative/path"] }` |
| `loam worktree new <plot> <repo> <name> --dry-run [--base <branch>] [--goal <text>] [--link <link-id or URL>]` | A check result. See below. |
| `loam worktree edit <plot> <worktree> --goal <text> [--repo <repo>] [--expect worktree:<id>=<version>]` | `{ "change_id": 44, "plot": "k3v9q2mxa7", "worktree": {...} }` |
| `loam worktree list [<plot>] [--refresh [--worktree <worktree>] [--repo <repo>]]` | An array of worktree states, oldest first. It is `[]` when none exists. |
| `loam worktree rm <plot> <worktree> [--repo <repo>] [--force] [--open-pane <folder>]` | `{ "worktree": {...}, "branch_deleted": false, "branch_note": "..." }` |
| `loam worktree land <plot> <worktree> [--method squash\|merge\|rebase] [--auto] [--keep-worktree] [--keep-remote-branch] [--dry-run] [--repo <repo>] [--open-pane <folder>]` | A land result. See [Land, rerun, and update](#land-rerun-and-update). |
| `loam worktree rerun <plot> <worktree> [--repo <repo>]` | `{ "worktree": {...}, "pr": {...}, "runs": [{ "id": 1234, "started": true }], "skipped_checks": ["ci/legacy"] }` |
| `loam worktree update <plot> <worktree> [--repo <repo>]` | `{ "worktree": {...}, "pr": {...}, "fetched": true, "fetch_note": "..." }` |

`new` uses the branch if it exists. Otherwise it fetches from `origin` and starts a new branch, with no upstream, from `--base` or from the default branch of `origin`. A `--base` that names a local branch uses the local branch; `--base origin/<branch>` uses the remote branch. A failed fetch is a warning on stderr. It copies the files of the repo setting `copy` and of `.worktreeinclude` in the repo root (one path or glob for each line, relative to the repo root). It never overwrites a file and never runs the setup command. `<repo>` is a repo ID or a path.

`--goal` sets the goal. A goal of more than 20 words saves, with the warning "The goal has 24 words. The soft limit is 20 words. Shorten it." on stderr. `--link` takes the ID of a link of the plot, or a URL. A link ID copies the target and the label of that link, and records its ID. A URL must be a Linear issue or a GitHub issue, else `new` exits with code 2 and makes nothing. A URL gets a label from its target, as `loam link add` does, and does not go into the links of the plot. An unknown link ID exits with code 1. Loam never fetches the issue.

`new --dry-run` changes nothing and never asks `origin`, so the app can run it as you type. The branch checks and the default base read the last fetched state. A repo, a `--link`, or a `--base` that `new` would refuse fails as it fails `new`, with one exception: when the branch exists, the dry run reports `branch_exists: true` and does not check `--base`. The app sends its base as you type, and `branch_exists` tells it that the base does not apply. `new` with `--base` for a branch that exists still exits with code 2. A name that is not a good branch name is a result, not a failure:

```json
{ "name": "fix-login", "folder": "web-fix-login", "valid_name": true, "worktree_exists": false, "branch_exists": false,
  "default_base": "origin/main", "bases": ["origin/main", "origin/develop", "develop", "main"] }
```

- `valid_name` is false when the name is not a good branch name. `name_error` then says why. It is left out when the name is valid.
- `worktree_exists` is true when the plot already has the worktree, or its folder exists. `new` would refuse it.
- `branch_exists` is true when a local branch or a branch of `origin` has the name. `new` then uses that branch, and a `--base` does not apply. It is false when the name is not valid.
- `default_base` is the base of a new branch when no `--base` is given. It comes from `origin/HEAD` of the last fetch. It is empty when the last fetch did not record `origin/HEAD`, or the repo has no `origin`. `new` without `--base` then asks `origin`.
- `bases` are the branches that a new branch can start from: `default_base` first, then the branches of `origin`, then the local branches, each with the newest commit first.

`edit` sets the goal as one change in the change log, with the entry `{ "item": "worktree:<id>", "field": "goal" }`. `loam undo` puts the old goal back. An empty `--goal` clears the goal, and `edit` without `--goal` exits with code 2. `change_id` is 0 when the goal is the same. `<worktree>` is an ID, a folder name, or a name, as for `rm`.

MCP `create_worktree` takes `goal` and `link`, as `--goal` and `--link`. MCP `set_worktree_goal` takes `worktree_id` and `goal`, and checks the goal version that Claude read with `list_worktrees` or `create_worktree`. `get_plot` does not show the goals, so it is not a read of them. `list_worktrees` returns the goal and the link of each worktree.

A worktree state, an item of `list`:

```json
{ "worktree": {...}, "missing": false, "changed": 0, "unpushed": 0, "merged": true, "merged_into": "origin/main",
  "stage": "ready_to_merge", "pr": {...}, "pr_note": "", "pr_checked_at": "2026-10-02T09:00:00Z" }
```

- `changed` counts the files with uncommitted changes, untracked files included. `unpushed` counts the commits that no remote branch holds. `merged` is true when the branch holds nothing that `merged_into` lacks. `merged_into` is left out when no branch to check against is known.
- The checks read the last fetched state. `error` is present when a check failed. `missing` is true when the folder is gone.
- `stage`, `pr`, `pr_note`, `pr_checked_at`, and `compare_url` are the ship state. See [Ship state of worktrees](#ship-state-of-worktrees).

`rm` takes a worktree ID, a folder name such as `web-fix-login`, or a name. It exits with code 1 and removes nothing in these cases:

- A pane is open in the worktree. The app passes the folder of each open pane with `--open-pane` (repeatable). The core also reads the panes in `state.json`. `--force` does not skip this check.
- The worktree has uncommitted changes or unpushed commits, and `--force` is missing. When the PR cache says that the PR of the branch is `MERGED`, and HEAD and the branch tip are the PR's `head_oid`, the commits of the branch are in the PR, and none counts as unpushed. After a squash or rebase merge, GitHub can delete the branch, and a fetch prunes `origin/<branch>`, so no remote branch holds those commits.

It deletes the local branch with `git branch -d`, so `branch_deleted` is false and `branch_note` says why when the branch is not merged. `branch_note` is left out when the branch was deleted. A squash or rebase merge leaves the commits of the PR off the base branch, so `git branch -d` refuses. So when the PR cache says that the PR of the branch is `MERGED`, and the branch tip is the PR's `head_oid`, `rm` uses `git branch -D`. A branch with a commit after the PR head keeps `-d` and the note. `rm` never deletes a remote branch.

`state.json` is in `~/Library/Application Support/Loam/`, where the app keeps its state (`LOAM_APP_STATE_DIR` replaces the folder in tests). Its minimal shape is below. A missing file means no open panes. The app writes the panes that it has open or has saved and not yet resumed. The app can add other fields; the core ignores them.

```json
{ "panes": [{ "plot_id": "k3v9q2mxa7", "folder": "/abs/path/of/the/pane/working/folder" }] }
```

A pane in Home (see [Home sessions](#home-sessions)) has `"home": true` and an empty `plot_id`, so it matches no plot.

### Ship state of worktrees

`loam worktree list` shows the pull request (PR) of the branch of each worktree, from GitHub only. Without `--refresh`, it reads the PR cache in the store and does not use the network. `--refresh` asks GitHub first and writes the cache. `--worktree <worktree>` refreshes only that worktree (an ID, a folder name, or a name); the output still lists every worktree. `--worktree` needs a plot and `--refresh`, and `--repo` needs `--worktree`. Each other use exits with code 2. MCP `list_worktrees` takes `refresh` (a boolean) and does the same as `--refresh`.

A refresh runs `gh api graphql`, so gh holds the sign-in and Loam holds no credentials. Loam finds gh on `PATH`, else in `/opt/homebrew/bin`, `/usr/local/bin`, or `/opt/local/bin` (`LOAM_GH` replaces the search in tests). Each repo gets at most two queries for each refresh: one for the PRs and the branches on GitHub, and one for the checks and reviews of the open PRs. Each gh call stops after 15 seconds. Ctrl-C, or a cancelled MCP call, stops gh. Then the refresh writes nothing, and the command fails. The owner and the name come from the `origin` remote. A repo whose `origin` is not on github.com gets no query. A worktree whose folder is gone gets no query and shows no ship state.

The cache writes do not rewrite `loam.changed`, so a refresh does not wake the app's change feed. The app gets the ship state from the command that it runs. A cache write skips a worktree that `loam worktree rm` removed while the refresh ran.

The ship state of a worktree:

- `stage` is one stage from the table below, or empty when there is nothing to show.
- `pr` is the PR object, or null when no PR has the branch as its head. A PR from a fork does not count. When two PRs share the head, the open one wins; else the newest wins. `pr` is also null when the stage comes from the local checks after a merged or closed PR (see below).
- `pr_note` says why the ship state is missing or old. It is the result of the last refresh, and it stays until a refresh gets an answer. It is one of these values:
  - empty: the last refresh got an answer, or no refresh ran.
  - `gh_missing`: gh is not installed.
  - `gh_signed_out`: gh exits with code 4, or GitHub gives HTTP 401.
  - `rate_limited`: GitHub refused the request for its rate limit (a "rate limit" message, or HTTP 429).
  - `no_access`: gh cannot read the repo. gh prints HTTP 403, HTTP 404, "Could not resolve to a Repository", or a SAML or SSO message. A rate limit with HTTP 403 is `rate_limited`.
  - `no_github_remote`: `origin` is not on github.com. `pr` is null.
  - `offline`: no network, a timeout, or another failed call.
- With `gh_missing` or `gh_signed_out`, Loam cannot ask GitHub until you fix gh, so the last state can stay old for a long time. The list then shows the local stage of each worktree: `pr` is null, and `pr_checked_at` and `compare_url` are left out. The cache keeps the last state, and the next refresh that gets an answer replaces it.
- Any other failed refresh keeps the last ship state and its `pr_checked_at`. When only the second query fails, a worktree with no PR, or with a merged or closed PR, still gets its new state, because it needs nothing from that query. A worktree with an open PR keeps its last state. Each worktree of the repo gets the note.
- `pr_checked_at` is when the ship state came from GitHub. It is left out when GitHub never answered for the branch, and with `gh_missing` or `gh_signed_out`.
- `compare_url` is the GitHub page where you can open a PR for the branch. It is present only for `pushed_no_pr`. When the base of the worktree is a branch of `origin` (`origin/<base>`), the page compares the branch with that base. Else GitHub compares the branch with the default branch of the repo.

Loam checks the stages in this order. The first match wins.

| Stage | When |
| :- | :- |
| `merged` | `state` is `MERGED`, and the worktree has no work after the PR head |
| `closed` | `state` is `CLOSED`, and the worktree has no work after the PR head |
| `in_merge_queue` | `in_merge_queue` is true |
| `conflicts` | `mergeable` is `CONFLICTING`, or `merge_state` is `DIRTY` |
| `changes_requested` | `review_decision` is `CHANGES_REQUESTED` |
| `checks_failed` | a required check is `FAILURE`, `ERROR`, `TIMED_OUT`, or `STARTUP_FAILURE`. When no check is required (`checks.required` is 0), any failed check counts. |
| `approval_needed` | a check is `WAITING` or `ACTION_REQUIRED` (`checks.waiting` is not 0) |
| `draft` | `draft` is true |
| `behind_base` | `merge_state` is `BEHIND` |
| `checks_running` | `checks.state` is `PENDING` or `EXPECTED`, or a check still runs |
| `waiting_for_review` | `review_decision` is `REVIEW_REQUIRED` |
| `blocked` | `merge_state` is `BLOCKED` |
| `ready_to_merge` | `merge_state` is `CLEAN`, `HAS_HOOKS`, or `UNSTABLE` (only optional checks failed) |
| `pushed_no_pr` | the branch is on GitHub, and no PR has it as its head |
| `not_pushed` | `changed` or `unpushed` is not 0 |

- "No work after the PR head" means that the worktree has no changed files, and its HEAD is the PR's `head_oid` or an earlier commit of the PR. GitHub can add commits to a PR, such as with Update branch. When the local repo does not have `head_oid`, Loam cannot read the history of the PR, and the worktree gets its local stage. When git cannot read the changed files or the unpushed commits, the worktree gets its local stage too. A squash merge leaves commits that no remote branch holds, and GitHub can delete the branch, but the worktree is still `merged`. New work after a merged or closed PR gets `pushed_no_pr`, `not_pushed`, or no stage from the local checks, as if there were no PR, and `pr` is null. A cache row from before Loam stored `head_oid` keeps `merged` or `closed`.
- `mergeable` is `UNKNOWN` while GitHub checks whether an open PR can merge. Only `conflicts`, `behind_base`, `blocked`, and `ready_to_merge` need that check, so Loam skips them and still checks the other stages. When no other stage matches, the stage of the last refresh of the same PR stays if it is one of those four. Else the stage is `checks_running`. A `merge_state` that Loam does not know is handled in the same way.
- An open PR always gets a PR stage. It never gets `pushed_no_pr`, `not_pushed`, or no stage.
- GitHub gives `BLOCKED` for each rule that stops a merge, such as unresolved conversations or required signatures. That includes a failed required check after the first 100 checks, which Loam does not read. So that PR shows `blocked`, never `ready_to_merge`.

The PR object:

```json
{
  "number": 12, "title": "Fix the login form", "url": "https://github.com/example/widgets/pull/12",
  "state": "OPEN", "draft": false, "mergeable": "MERGEABLE", "merge_state": "BLOCKED", "review_decision": "REVIEW_REQUIRED",
  "in_merge_queue": false, "queue_position": 0, "base": "main", "head": "fix-login", "head_oid": "1f0c...",
  "commits": 3, "behind_base": 2, "approvals": 1, "comments": 3,
  "checks": { "state": "FAILURE", "total": 14, "passed": 12, "failed": 2, "running": 0, "waiting": 0, "required": 14, "required_passed": 12 },
  "failed_checks": [{ "name": "lint / swiftformat", "url": "https://github.com/...", "duration": 42, "required": true, "run_id": 1234 }]
}
```

- `state` is `OPEN`, `CLOSED`, or `MERGED`. `mergeable`, `merge_state` (GitHub's `mergeStateStatus`), and `review_decision` are the values of GitHub. `review_decision` is empty when the base branch needs no review.
- `merged_at` and `closed_at` are present when the PR is merged or closed.
- `queue_position` counts from 1. It is 0 when the PR is not in the merge queue.
- `behind_base` counts the commits of the base branch that the head does not have. `approvals` counts the reviewers with write access whose last review approves. `comments` counts the review threads that are not resolved.
- `checks` counts the checks of the head commit. `checks.state` is GitHub's summary, empty when the head has no checks. A cancelled or stale check counts only in `total`. `required` counts the checks that the base branch needs to pass before a merge, and `required_passed` counts those that passed. For an `UNSTABLE` PR, the app can write "14 of 14 required checks passed · 2 optional failed".
- `failed_checks` lists each failed check. A GitHub Actions job has its workflow name first. `duration` is in seconds, 0 when GitHub gives no start or end. `required` is true for a required check. `run_id` is the GitHub Actions run of the check, which `loam worktree rerun` runs again. It is left out for a check that is not a job of GitHub Actions.
- Loam reads one page of 100 checks and 100 review threads, to keep to two queries for each repo. `checks.total` counts every check. The other check counts, `failed_checks`, and `comments` cover the first 100.
- `behind_base`, `approvals`, `comments`, `checks`, and `failed_checks` are for an open PR. They are 0 or empty for a merged or closed PR.

### Land, rerun, and update

`loam worktree land` merges the PR of a worktree on GitHub. Then it deletes the branch on GitHub and removes the worktree. `rerun` runs the failed checks of the PR again, and `update` brings the PR up to date with its base branch. Each command acts on GitHub through gh, as a refresh does (see [Ship state of worktrees](#ship-state-of-worktrees)). Each one refreshes the PR first, and fails when the refresh gets no answer, so Loam never acts on an old state:

- gh is missing or signed out, or `origin` is not on github.com: exit code 17 (`gh_unavailable`).
- GitHub gives no answer, a rate limit, or no access: exit code 1.
- The branch has no PR, or the folder of the worktree is gone: exit code 1.

A command that acts on GitHub stops after one minute. Ctrl-C stops gh, but GitHub keeps an action that it has. GitHub's message for a refused action, such as a merge, comes back as exit code 1.

The land result:

```json
{
  "worktree": {...}, "pr": {...}, "stage": "ready_to_merge", "changed": 0, "unpushed": 0,
  "methods": ["merge", "squash"], "default_method": "squash", "method": "squash", "merge_queue": false, "auto": false,
  "checks": [
    { "name": "checks", "state": "passed", "blocks": false },
    { "name": "review", "state": "approved", "blocks": false },
    { "name": "behind_base", "state": "up_to_date", "blocks": false },
    { "name": "conflicts", "state": "none", "blocks": false },
    { "name": "github", "state": "clear", "blocks": false },
    { "name": "local_changes", "state": "none", "blocks": false },
    { "name": "unpushed_commits", "state": "none", "blocks": false }
  ],
  "ready": true, "dry_run": false, "merged": true, "merge_later": false,
  "remote_branch_deleted": true, "worktree_removed": true, "branch_deleted": true
}
```

- `pr` and `stage` are from the refresh before the merge. `changed` and `unpushed` are the local checks of the worktree.
- `methods` lists the merge methods that the repo allows. `default_method` is the method that GitHub offers first: the method that you last used in the repo, else the default of the repo. `merge_queue` is true when the base branch has a merge queue.
- `method` is the method of the land: `--method`, else `default_method`. It is empty with a merge queue, which merges with its own method. `--method` with a merge queue, or a method that the repo does not allow, exits with code 2.
- `ready` is true when no check blocks. `merged` is true when GitHub says that the PR is merged. For a merged PR, `methods` and `default_method` are empty, and `checks` has `work_after_pr` only. `merge_later` is true when GitHub merges later, and when Loam cannot see the merge yet (`merge_note` says why).
- `worktree` has the `land` that the worktree records after the land. It has no `land` after a merge, and after a removal.
- The notes `merge_note`, `remote_branch_note`, `worktree_note`, and `branch_note` say why a step did not happen. Each is left out when it does not apply.

The checks of an open PR, in this order. A merged PR has the check `work_after_pr` only.

| Check | States | Blocks |
| :- | :- | :- |
| `checks` | `passed`, `failed`, `running`, `waiting`, `none` | `failed`: a check failed, as the stage `checks_failed` counts it |
| `review` | `approved`, `changes_requested`, `required`, `none` | `changes_requested` |
| `behind_base` | `up_to_date`, `behind` | when `merge_state` is `BEHIND`: the base branch needs the PR up to date. A PR that is only behind (`behind_base` is not 0) does not block. |
| `conflicts` | `none`, `conflicting`, `checking` | `conflicting`, as the stage `conflicts` counts it |
| `github` | `clear`, `blocked`, `draft`, `checking` | `draft`: the PR is a draft. GitHub does not merge a draft, so it blocks an auto merge and a merge queue too. `blocked`, for a merge now. `blocked` is the stage `blocked`: GitHub blocks the merge for a reason that no other check covers. An auto merge and a merge queue wait for GitHub, so `blocked` does not block them. |
| `local_changes` | `none`, `changed`, `unknown` | `changed` or `unknown` |
| `unpushed_commits` | `none`, `unpushed`, `unknown` | `unpushed` or `unknown` |
| `work_after_pr` | `none`, `found`, `unknown` | `found` or `unknown`. Only for a merged PR. `found` means that the worktree has work after the PR head, which the PR does not have. It is the rule of the stage `merged`: the worktree has no work after the PR head when its HEAD is the PR's `head_oid` or an earlier commit of the PR, and no file has changes. When the local repo does not have `head_oid`, Loam cannot tell, and the state is `found`. |

- `checking` means that GitHub still checks whether the PR can merge (`mergeable` is `UNKNOWN`). `unknown` means that git could not read the local checks.
- While GitHub checks, the stage rule keeps the last stage of the PR when it is `conflicts`, `behind_base`, or `blocked` (see [Ship state of worktrees](#ship-state-of-worktrees)). Then the check of that stage blocks as if GitHub had answered.
- `running`, `waiting`, `required`, and `checking` do not block. When GitHub refuses the merge for one of them, its message comes back as exit code 1.

A land runs these steps:

1. It refreshes the PR.
   - A closed PR exits with code 1. Without `--dry-run`, the land clears the `land` that the worktree records, and the message says so.
   - For a merged PR, the land runs the check `work_after_pr`. With `--dry-run`, it stops there and prints the result. When the check blocks, the land removes nothing and deletes nothing. It clears the `land` that the worktree records, and exits with code 16 (`not_ready`). The message says that it cleared the `land`. Else the land skips to step 6.
2. It reads the merge settings of the repo and of the base branch from GitHub.
3. It runs the checks. With `--dry-run`, it stops here and prints the result, also when a check blocks (exit code 0). Else, when a check blocks, it exits with code 16 (`not_ready`).
4. When it removes the worktree right after the merge, it refuses while a pane is open in the worktree, as `rm` does: exit code 1. The app closes the panes first, or passes `--keep-worktree`.
5. It runs `gh pr merge` with the method and `--match-head-commit`, so GitHub refuses the merge when the PR has a commit that Loam did not check. With `--auto`, GitHub merges when the checks pass. With a merge queue, GitHub adds the PR to the queue. Then the land refreshes the PR again.
6. When GitHub says that the PR is merged, the land deletes the branch on GitHub, unless `--keep-remote-branch` (see below). Then the land removes the worktree as `rm` does, unless `--keep-worktree`. A step that fails is a note, and the exit code is 0.
7. When GitHub merges later, the land records its options in `land` on the worktree and keeps the worktree. A later land of a merged PR does step 6 and clears `land`, also when the worktree stays.

The delete of the branch on GitHub:

- The land reads the branch first. A branch with commits after the PR head stays.
- A branch that GitHub already deleted counts as deleted: the read gives HTTP 404, or the delete gives HTTP 404, or HTTP 422 with "Reference does not exist".
- GitHub also gives HTTP 422 when it refuses the delete, such as for a protected branch or a ruleset. After another HTTP 422, the land reads the branch again. The branch counts as deleted only when that read gives HTTP 404.
- A branch that stays has `remote_branch_note`, with the reason.

A later land applies the keeps in `land`: a recorded `keep_worktree` or `keep_remote_branch` stays a keep, and the flags of the later land can only add keeps. So a land again with no flags finishes a land as its first run said.

When the refresh after the merge fails, or the PR does not show a merge that GitHub made, `merge_note` says so, and the land records its options as in step 7. When gh stops before GitHub answers the merge (a timeout or Ctrl-C), GitHub may have the land. The land records its options as in step 7, and exits with code 1. The message says to run the land again.

`rerun` runs `gh run rerun <run> --failed` once for each GitHub Actions run with a failed check (see `run_id`). It tries every run, also after GitHub refuses one. `runs` lists those runs:

```json
[{ "id": 301, "started": true }, { "id": 302, "started": false, "note": "could not re-run the run 302: ..." }]
```

- `started` is true when GitHub runs the failed jobs of the run again.
- `note` is the message of GitHub for a run that did not start. It is left out when the run started.
- When no run started, the command exits with code 1, and the message has the reason for each run.

`skipped_checks` lists the failed checks that are not jobs of GitHub Actions. `runs` and `skipped_checks` are `[]` when none. The PR must be open, else the command exits with code 1.

`update` runs `gh pr update-branch`, so GitHub adds a merge commit of the base branch to the PR. Then it fetches the branch from `origin`, so the local repo has the new PR head, and the stage rule can see that the worktree is in the PR. It does not change the branch of the worktree. `fetched` is false when the fetch failed, and `fetch_note` says why. GitHub still has the update. The PR must be open, else the command exits with code 1.

### Sessions

`loam sessions [<plot>] --json` prints an array of session records, newest first. It is `[]` when no record exists.

```json
[{ "session_id": "...", "plot_id": "k3v9q2mxa7", "start_folder": "/abs/path", "created_at": "2026-10-02T09:00:00Z" }]
```

### Plot order

`loam move <plot> <position> --json` moves a plot to a position in the plot order. The first position is 1. A position outside 1 to the plot count exits with code 2. A move writes no change log entry.

```json
{ "plot": "k3v9q2mxa7", "position": 1 }
```

### Archive and delete

`loam archive <plot> --json` and `loam unarchive <plot> --json` print the plot object after the call. Both do nothing when the plot is already in that state. The archived flag is not a change: it has no change log entry, no `change_id`, and no undo. An archived plot keeps its place in the plot order, so an unarchived plot returns to its old place.

An archived plot leaves `loam list` and MCP `list_plots`. `loam list --archived` lists only archived plots. MCP `list_plots` takes `archived: true` for the same list, and each row has `archived`. MCP `get_plot` has `archived` too. Reads and edits of an archived plot still work. The commands start and resume exit with code 1 and a message that says "unarchive first". They write nothing and start no session. No MCP tool archives or deletes.

`loam delete <plot> --json` deletes an archived plot that has no worktrees. It removes the plot, its change log, its session records, and the repo settings that no other plot uses. It moves the plot folder to `~/.Trash/<folder name>`. A name that is taken gets a number: `<name> 2`. There is no undo.

```json
{ "plot": "k3v9q2mxa7", "name": "Loam", "trash": "/Users/me/.Trash/k3v9q2mxa7", "claude_files": ["/Users/me/.claude/projects/-Users-me-code-loam"] }
```

- `trash` is empty when the plot had no folder.
- `claude_files` holds the folders under `~/.claude/projects/` that Claude Code made for the start folders of the plot's sessions. Claude Code names each folder after the start folder, with every `/` and `.` changed to `-`. The list holds only folders that exist, once each. It is `[]` when there are none. Loam does not remove them. With `CLAUDE_CONFIG_DIR` set, the folder is `$CLAUDE_CONFIG_DIR/projects/`.
- A plot that is not archived, and a plot with worktrees, exit with code 1. The message says what to do first.

### Export

`loam export [--changes]` always prints JSON, with or without `--json`. `plots` holds the plot objects in the plot order. `changes` is present only with `--changes`. It holds every change, oldest first.

```json
{
  "plots": [ /* plot objects */ ],
  "changes": [
    {
      "id": 41,
      "plot_id": "k3v9q2mxa7",
      "at": "2026-10-02T09:00:00Z",
      "actor": { "kind": "cli" },
      "entries": [{ "item": "what", "field": "value", "old": "...", "new": "..." }],
      "undo_of": null
    }
  ]
}
```

- `old` is `null` for a new item. `new` is `null` for a removed item.

### Setup check

`loam setup --check --json` reports each setup step. It asks nothing and changes nothing. It exits with code 0 whether or not the steps are done.

```json
{
  "ok": false,
  "steps": [
    { "id": "mcp", "done": true },
    { "id": "trust", "done": false, "detail": "Claude Code has not trusted the plots folder" }
  ]
}
```

- `ok` is true when every step is done.
- The step IDs are `mcp` (the MCP server is registered with this binary) and `trust` (Claude Code trusts the plots folder). A later version can add steps, so the app must ignore IDs it does not know.
- `detail` is for a person to read. It is present only for a step that is not done.

### `loam changes [<plot>] [--since <id>] --json`

The change log, newest last. Without a plot it covers every plot. `--since` returns only changes with an ID above it, so the app polls with the highest ID it has seen.

```json
{ "changes": [ { "id": 43, "plot_id": "...", "at": "...", "actor": { "kind": "cli|app|session", "session_id": "...", "loam_started": true }, "entries": [ { "item": "what", "field": "value", "old": "a", "new": "b" } ], "undo_of": null } ] }
```

- Items are `name`, `what`, `why`, `where`, `link:<id>`, `repo:<id>`, and `worktree:<id>`. The field of a worktree entry is `goal`.
- `undo_of` is the ID of the change that this change reverted, or null. The app reads it to show "undone HH:MM". MCP `get_changes` returns it too.
- A null `old` means the item is new. A null `new` means the change removed the item.
- `changes` is `[]` when nothing matches.

### `loam undo <change-id> [--overwrite] --json`

Writes the old values back as a new change by the actor (`--actor app` for the app). The change log keeps every entry.

```json
{ "change_id": 44, "undone": 41, "plot": "k3v9q2mxa7" }
```

- `change_id` is 0 when the undo changed nothing.
- A later change to the same item gives exit code 11 and the `undo_clash` error with its details. Nothing is written. Run again with `--overwrite` to write anyway.
- Undo of plot creation is `invalid` (exit code 2). An unknown change ID is `error` (exit code 1).
- Undo of a link or repo add removes it. Undo of a remove puts it back with its ID and position.
- Undo of a goal edit of a worktree that `loam worktree rm` removed is `error` (exit code 1). Nothing is written.

### Commands without JSON output

| Command | Why |
| :- | :- |
| `loam start` | It replaces the process with `claude`. `--repo` takes a repo ID or a path. `--plot-folder` starts in the plot folder of a plot with repos, and every repo is then an added folder; it fails with exit code 2 (`invalid`) with `--repo` or `--worktree`. An unknown repo exits with code 1, as in `loam repo edit`. Each local link adds its folder (or the folder of the file) with `--add-dir`, except the root, the home folder, and a parent of the home folder: a link to one of them adds nothing. |
| `loam mcp` | It speaks the MCP protocol on stdio. |
| `loam hook` | It is hidden. It speaks the Claude Code hook protocol. |
| `loam setup` | It is interactive. Use `loam setup --check --json` instead. |
| `loam resume <session-id> [--plot <plot>]` | It replaces the process with `claude --resume`. |

### Home sessions

`loam start --home [--session-id <uuid> | --resume <uuid>]` starts a session that belongs to no plot. The app uses it for Home, its space for tabs with no plot. The session starts in the home folder. It gets no seed, no `--add-dir`, and no `LOAM_PLOT`, but it gets the same settings file as a seeded session, so the pane hooks and the allow rules work. It adds no session record, so `loam sessions` does not list it and `loam resume` does not know it. `--resume` runs `claude --resume` in the home folder, where Claude Code finds the session.

`--home` with a plot, or with `--repo`, `--worktree`, or `--plot-folder`, exits with code 2 (`invalid`). So do `--resume` without `--home`, `--resume` with `--session-id`, and a value that is not a UUID.

`loam resume <session-id> --plot <plot>` moves a Home session into a plot. The app runs it when you move a Home tab to a plot. When the session has no record, it adds a record in the plot, with the home folder as the start folder, because a Home session always runs there. Then it resumes the session as `loam resume` does: with the seed, the `--add-dir` folders, and `LOAM_PLOT`. It adds the record only when the launch plan is ready, so a failed check leaves no record. When the session is already recorded in that plot, it resumes it. When Claude Code keeps no conversation for the session (no `projects/*/<session-id>.jsonl` in `CLAUDE_CONFIG_DIR`, else `~/.claude`), for example because it never had a prompt, the session starts again with `--session-id` and the same ID. When the session is recorded in another plot, it exits with code 2 (`invalid`), so a session never moves between plots. So does a session ID that is not a UUID. An archived plot is refused as for `loam start`. The record writes no change.

### Worktree sessions

`loam start <plot> --worktree <worktree> [--repo <repo>]` starts the session in the worktree, with no `--add-dir` for the normal checkout of its repo. Before the first session in a worktree, it prints "Claude will ask to trust this folder, choose Yes." While `setup_done` is false, it runs the setup command in the worktree before it starts `claude`, and records a success. A failed setup prints a warning, and `claude` still starts. A setup command runs with no question only when you approved that exact text: a command you set with `loam repo add` or `loam repo edit --setup` is approved, and one set through MCP (`add_repo`, `update_repo`) is not. For a new or changed command, `loam start` shows it and asks "Run it? [y/N]" on a terminal; with no terminal it skips the command with a warning. A yes approves the command, and `claude` starts either way. `loam resume` does the same, and fails if the worktree folder is gone. The app starts each worktree pane with `loam start --worktree` or `loam resume`, so each new pane runs setup again until it succeeds.

## Pane socket

The app runs each pane. It sets `LOAM_PANE_SOCKET` in the pane environment to the path of a Unix socket that it listens on. A session that `loam start` or `loam resume` runs in the pane registers `loam hook` for the hook events below. A session outside the app has no `LOAM_PANE_SOCKET`, and `loam hook` sends nothing.

For each hook event in the table, `loam hook` connects to the socket and writes one line. The line is one JSON object and a newline. Then it closes the connection. The app reads lines until the connection closes. It may get lines from many sessions.

```json
{ "event": "SessionStart", "session_id": "11111111-2222-4333-8444-555555555555", "cwd": "/abs/path", "source": "startup", "at": "2026-10-02T09:00:00Z" }
```

| Field | Meaning |
| :- | :- |
| `event` | The hook event name |
| `session_id` | The Claude Code session ID |
| `cwd` | The working folder that Claude Code reports |
| `source` | Only on `SessionStart`: `startup`, `resume`, `clear`, or `compact` |
| `notification_type` | Only on `Notification`: `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, or `permission_prompt` |
| `at` | The time of the hook call, in UTC |

| Event | When |
| :- | :- |
| `SessionStart` | A session starts, resumes, clears, or compacts |
| `SessionEnd` | A session ends |
| `UserPromptSubmit` | You send a prompt. The line does not hold the prompt. |
| `Stop` | Claude finishes its turn |
| `PermissionRequest` | Claude asks you to allow a tool |
| `Notification` | Claude needs your input. Only the three types above raise a line. `idle_prompt` and other types raise nothing. |
| `PostToolUse` | A tool call ends. The line does not hold the tool input or output. |
| `StopFailure` | A turn ends with an API error |

A subagent stop (`SubagentStop`) raises nothing.

- The app must ignore events and fields that it does not know. A later version adds events with no change of the contract version.
- `loam hook` never fails and never blocks. It waits at most 200 ms to connect and 200 ms to write. When the socket is missing, dead, or slow, it drops the line, writes the error to `hook.log` in the Loam home folder, and exits with code 0.
- The event table is `paneEvents` in `core/internal/session/panesocket.go`.

## Settings file

`<LOAM_HOME>/settings.json` holds the settings that differ from one machine to the next (ADR 0006). The app reads and writes it, and the settings window edits it. The core does not read it yet. You can edit the file by hand. The app watches it and applies a change at once.

```json
{
  "repo_folders": ["~/Development"],
  "loam_path": null
}
```

| Key | Meaning | Default |
| :- | :- | :- |
| `repo_folders` | The folders whose git checkouts the add repo row offers, next to the folders of known repos | `["~/Development"]` |
| `loam_path` | The `loam` binary that the app runs. Null means Automatic: `~/.local/bin/loam`, `/opt/homebrew/bin/loam`, `/usr/local/bin/loam`, `Loam.app/Contents/Helpers/loam` (a release has it), then the PATH. The app reads it at launch. | `null` |

- A missing file or a missing key gives the default. The app writes the file only when you change a setting.
- A path can start with `~`. The app keeps it as written and expands it when it reads it.
- A write keeps the keys that the app does not know, so a later key for the core survives an edit in the window.
- The app never replaces a file that holds invalid JSON. It shows the error in the settings window. At launch it uses the defaults. While it runs, it keeps the last good settings.
