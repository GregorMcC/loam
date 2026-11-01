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

- `checks` lists each check that blocks the land, in the order of the land result. See [Land, rerun, and update](#land-rerun-and-update). For a land of an open PR that is not a dry run, the list is empty when `--head` names another commit than the PR head: no check blocks, and the message says that the PR has new commits, or that the PR does not have the commit that `--head` names.

Details of an `error` that refuses `loam worktree rm` (ticket 113). Other errors of kind `error` have no details.

```json
{ "refusal": "unsafe_work", "changed": 1, "unpushed": 2, "check_error": "git status failed" }
{ "refusal": "open_panes", "open_panes": 1 }
```

- `refusal` is `unsafe_work` or `open_panes`.
- `unsafe_work` has `changed`, `unpushed`, and `check_error`. Each one is left out when it is 0 or empty. `unpushed` leaves out the commits that the merged PR holds.
- `open_panes` has the number of panes that are open in the worktree.
- The message names flags of the CLI, such as `--force`. The app words the refusal from the details.

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
  "repos": [{ "id": "...", "path": "/abs/path", "note": "", "main": true, "version": 12, "setup": "npm ci", "copy": [".env"], "after_merge": "ask" }],
  "versions": { "name": 12, "what": 12, "why": 12, "where": 40, "link:<id>": 12, "repo:<id>": 12 },
  "revision": 40
}
```

- `setup`, `copy`, and `after_merge` in a repo are the worktree settings of the repo path. `setup` and `copy` are left out when empty. `after_merge` is always present: `ask` (the default), `remove`, or `keep`. See "Worktrees".
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
| `loam repo add <plot> <path> [--note] [--setup] [--copy] [--after-merge]` | `change_id`, `plot`, `repo` |
| `loam repo edit <plot> <repo> [--note] [--setup] [--copy] [--after-merge]` | `change_id`, `plot`, `repo` |
| `loam repo main <plot> <repo>` | `change_id`, `plot`, `repo` |
| `loam repo rm <plot> <repo> [--main <repo>]` | `change_id`, `plot` |

`loam link add` with no label, or MCP `add_link` with no `label`, takes the label from the target. A local path gives the file name with no extension, or the folder name. GitHub gives `<repo> on GitHub`, or `<repo>#<n>` for an issue or pull request. Linear gives the issue ID, Notion the page title, Obsidian the note name, and any other URL the host.

`loam repo add`, MCP `add_repo`, and MCP `create_plot` expand a leading `~`. They fail with exit code 2 (`invalid`) when the repo path does not exist or is a file. The message names the path.

`loam repo add` also adds the repo's git remote as a link, in the same change, so one undo removes both. It uses `origin`, else the first remote, as a web URL with no user name or token. It adds no link when the folder has no remote, the remote is a local path, or the plot already has a link to that URL. MCP `add_repo` and `create_plot` do the same. `repo` in the output is still the new repo.

After the add, `loam repo add` puts the checkout on the default branch of `origin`. It fetches `origin`, switches the checkout to that branch (it makes the local branch from `origin/<branch>` if needed), and fast-forwards it to `origin/<branch>`. A checkout with uncommitted changes to tracked files keeps its branch. Untracked files do not count. The add still succeeds. Loam does nothing to a repo with no commits or no `origin`, or to a linked worktree. What Loam could not do is a warning on stderr and, with `--json`, in `warnings`. MCP `add_repo` and `create_plot` do the same and return `warnings`. Every plot that holds the path shares the checkout, so the switch shows in each of them.

`loam repo rm` of the main repo needs `--main` with `--json` or with no terminal, because the command cannot ask. Without it, the command exits with code 2 (`invalid`).

`loam repo rm` fails with exit code 1 while the plot has worktrees of the repo. The same holds for MCP `remove_repo`.

`--setup`, `--copy`, and `--after-merge` set the worktree settings of the repo path. `--copy` is repeatable. An empty value of `--setup` or `--copy` clears the setting. The settings are not a change: they have no change log entry and no undo, so `change_id` is 0 when only they changed. Every plot that holds the path shows the same settings.

`--after-merge` says what the app does when a refresh finds that GitHub merged the PR of a worktree of the repo, outside Loam: `ask` (the default) shows a callout with Keep and Remove worktree, `remove` removes the worktree when it holds no work, and `keep` does nothing. Any other value exits with code 2 (`invalid`) and changes nothing. MCP `add_repo` and `update_repo` take the same values as `after_merge`. The core only keeps the setting: it removes nothing by itself.

### Worktrees

A worktree is a separate checkout of one repo of a plot, on its own branch. It lives in `<loam home>/worktrees/<plot-id>/<repo folder>-<name>/`. Making or removing one is not a change in the change log. A goal edit is a change.

```json
{
  "id": "wtreeaaaab", "plot_id": "k3v9q2mxa7", "repo": "/abs/path/of/repo", "name": "fix-login", "branch": "fix-login",
  "base": "origin/main", "path": "/abs/path/of/worktree", "setup_done": false, "created_at": "2026-10-02T09:00:00Z",
  "goal": "Fix the login form",
  "link": { "target": "https://github.com/example/widgets/issues/57", "label": "widgets#57", "key": "#57", "link_id": "" },
  "version": 0,
  "land": { "pr": 12, "method": "squash", "auto": true, "merge_queue": false, "keep_worktree": false, "keep_remote_branch": false },
  "sessions": ["c57ef956-3136-4e86-bfde-da8facfe0523"]
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
- `sessions` are the IDs of the sessions that work in the worktree but started in another folder, oldest link first. It is `[]` when none does. A session works in one worktree at a time. MCP `create_worktree` links the session that calls it to the new worktree, and MCP `work_in_worktree` links it to another worktree of the plot, or clears the link when it has no `worktree_id`. After `/clear`, `loam hook` moves the link to the new session ID. A resume or a fork keeps it on the earlier ID. The link does not change the folder of the session, so Send to session puts the worktree folder first in the prompt of a linked session. The app shows the pane of a linked session under the worktree, with its PR. A link is not a change in the change log, and it goes when the worktree goes.
- `land` is a land that waits for GitHub to merge the PR: an auto merge, or a merge queue. It is also a land that GitHub may have when Loam cannot see the merge, and a land after a merge that waits for the panes of the worktree to close. It holds the options of `loam worktree land`, and a later land of the same PR (`pr`) applies its keeps. `method` is empty with a merge queue. `land` is left out when no land waits.

| Command | Output |
| :- | :- |
| `loam worktree new <plot> <repo> <name> [--base <branch>] [--goal <text>] [--link <link-id or URL>]` | `{ "worktree": {...}, "copied": ["relative/path"] }` |
| `loam worktree new <plot> <repo> <name> --dry-run [--base <branch>] [--goal <text>] [--link <link-id or URL>]` | A check result. See below. |
| `loam worktree edit <plot> <worktree> --goal <text> [--repo <repo>] [--expect worktree:<id>=<version>]` | `{ "change_id": 44, "plot": "k3v9q2mxa7", "worktree": {...} }` |
| `loam worktree list [<plot>] [--refresh [--worktree <worktree>] [--repo <repo>]]` | An array of worktree states, oldest first. It is `[]` when none exists. |
| `loam worktree rm <plot> <worktree> [--repo <repo>] [--force] [--dry-run] [--open-pane <folder>]` | `{ "worktree": {...}, "branch_deleted": false, "branch_note": "..." }`. A dry run adds `"dry_run": true`. |
| `loam worktree land <plot> <worktree> [--method squash\|merge\|rebase] [--auto] [--keep-worktree] [--keep-remote-branch] [--dry-run] [--head <commit>] [--repo <repo>] [--open-pane <folder>]` | A land result. See [Land, rerun, and update](#land-rerun-and-update). |
| `loam worktree rerun <plot> <worktree> [--repo <repo>]` | `{ "worktree": {...}, "pr": {...}, "runs": [{ "id": 1234, "started": true }], "skipped_checks": ["ci/legacy"] }` |
| `loam worktree update <plot> <worktree> [--repo <repo>]` | `{ "worktree": {...}, "pr": {...}, "fetched": true, "fetch_note": "..." }` |

`new` uses the branch if it exists. Otherwise it fetches from `origin` and starts a new branch, with no upstream, from `--base` or from the default branch of `origin`. A `--base` that names a local branch uses the local branch; `--base origin/<branch>` uses the remote branch. A failed fetch is a warning on stderr. It copies the files of the repo setting `copy` and of `.worktreeinclude` in the repo root (one path or glob for each line, relative to the repo root). It never overwrites a file and never runs the setup command. `<repo>` is a repo ID or a path.

`--goal` sets the goal. A goal of more than 20 words saves, with the warning "The goal has 24 words. The soft limit is 20 words. Shorten it." on stderr. `--link` takes the ID of a link of the plot, or a URL. A link ID copies the target and the label of that link, and records its ID. A URL must be a Linear issue or a GitHub issue, else `new` exits with code 2 and makes nothing. A URL gets a label from its target, as `loam link add` does, and does not go into the links of the plot. An unknown link ID exits with code 1. Loam never fetches the issue.

`new --dry-run` changes nothing and never asks `origin`, so the app can run it as you type. The branch checks and the default base read the last fetched state. A repo, a `--link`, or a `--base` that `new` would refuse fails as it fails `new`, with one exception: when the branch exists, the dry run reports `branch_exists: true` and does not check `--base`. The app sends its base as you type, and `branch_exists` tells it that the base does not apply. `new` with `--base` for a branch that exists still exits with code 2. A name that is not a good branch name is a result, not a failure:

```json
{ "name": "fix-login", "folder": "web-fix-login", "valid_name": true, "worktree_exists": false, "branch_exists": false,
  "default_base": "origin/main", "bases": ["origin/main", "origin/develop", "develop", "main"],
  "seed_line": "- web-fix-login: Fix the login form (#57, from origin/main)" }
```

- `valid_name` is false when the name is not a good branch name. `name_error` then says why. It is left out when the name is valid.
- `worktree_exists` is true when the plot already has the worktree, or its folder exists. `new` would refuse it.
- `branch_exists` is true when a local branch or a branch of `origin` has the name. `new` then uses that branch, and a `--base` does not apply. It is false when the name is not valid.
- `default_base` is the base of a new branch when no `--base` is given. It comes from `origin/HEAD` of the last fetch. It is empty when the last fetch did not record `origin/HEAD`, or the repo has no `origin`. `new` without `--base` then asks `origin`.
- `bases` are the branches that a new branch can start from: `default_base` first, then the branches of `origin`, then the local branches, each with the newest commit first.
- `seed_line` is the line that the seed of the plot gets for the worktree, with the `--goal`, the `--link` and the base of this check. The base is the `--base`, else `default_base`. A branch that exists has none. `seed_line` is left out when the name is not valid. The same code writes the seed line of `new`, so the line shows what the seed says. The exception is a new branch with no `--base` and an empty `default_base`: the line has no base, because the dry run does not ask `origin`, and `new` then writes the line with the base that `origin` gave, such as `from origin/main`. Give `--base` to make the two lines the same.

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
- The worktree has uncommitted changes or unpushed commits, and `--force` is missing. When the work of the worktree is in the merged PR (see below), none of its commits counts as unpushed. After a squash or rebase merge, GitHub can delete the branch, and a fetch prunes `origin/<branch>`, so no remote branch holds those commits.

`--dry-run` checks the work as a removal does and changes nothing. It does not check the open panes, so the app can run it before it closes the panes of the worktree (ticket 113). `branch_deleted` is `false` in a dry run.

A refusal is an `error` with details. See [The JSON error](#the-json-error).

The work of a worktree is in the merged PR when all of these are true. A land of a merged PR uses the same rule (the check `work_after_pr`).

- The PR cache says that the PR of the branch is `MERGED`.
- HEAD and the branch tip are the same commit. For a worktree whose folder is gone, the branch tip decides.
- That commit is the PR's `head_oid`, or an earlier commit of the PR. GitHub can add commits to a PR, such as with `loam worktree update`. For an earlier commit, the local repo must have `head_oid`. `rm` does not fetch it.
- No file has changes, and git could read the local checks.

It deletes the local branch with `git branch -d`, so `branch_deleted` is false and `branch_note` says why when the branch is not merged. `branch_note` is left out when the branch was deleted. A squash or rebase merge leaves the commits of the PR off the base branch, so `git branch -d` refuses. So when the work of the worktree is in the merged PR, `rm` uses `git branch -D`. A branch with a commit that is not in the PR keeps `-d` and the note. `rm` never deletes a remote branch.

`state.json` is in `~/Library/Application Support/Loam/`, where the app keeps its state (`LOAM_APP_STATE_DIR` replaces the folder in tests). Its minimal shape is below. A missing file means no open panes. The app writes the panes that it has open or has saved and not yet resumed. The app can add other fields; the core ignores them.

```json
{ "panes": [{ "plot_id": "k3v9q2mxa7", "folder": "/abs/path/of/the/pane/working/folder" }] }
```

A pane in Home (see [Home sessions](#home-sessions)) has `"home": true` and an empty `plot_id`, so it matches no plot.

### Ship state of worktrees

`loam worktree list` shows the pull request (PR) of the branch of each worktree, from GitHub only. Without `--refresh`, it reads the PR cache in the store and does not use the network. `--refresh` asks GitHub first and writes the cache. `--worktree <worktree>` refreshes only that worktree (an ID, a folder name, or a name); the output still lists every worktree. `--worktree` needs a plot and `--refresh`, and `--repo` needs `--worktree`. Each other use exits with code 2. MCP `list_worktrees` takes `refresh` (a boolean) and does the same as `--refresh`. Its result is the same JSON as `loam worktree list --json`, except that the `pr` of a worktree leaves out `passed_checks`, `change_requests`, and `review_threads`. A session reads them through gh, and up to 100 rows for each worktree would fill its context. `checks.passed` and `comments` still count them.

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
  "failed_checks": [{ "name": "lint / swiftformat", "url": "https://github.com/...", "duration": 42, "required": true, "run_id": 1234 }],
  "passed_checks": [{ "name": "test / macos-26", "url": "https://github.com/...", "duration": 190, "required": true, "run_id": 1235 }],
  "change_requests": [{ "id": "PRR_kwDO...", "author": "alice", "body": "Keep the old name as an alias.", "url": "https://github.com/...#pullrequestreview-1", "commit": "0a9b..." }],
  "review_threads": [{ "id": "PRRT_kwDO...", "path": "login/form.go", "line": 42, "url": "https://github.com/...#discussion_r1",
    "comments": [{ "author": "alice", "writer": true, "body": "This drops the error.", "url": "https://github.com/...#discussion_r1" }] }],
  "comment_reviews": [{ "id": "PRR_kwDO...", "author": "reviewbot", "body": "...", "url": "https://github.com/...#pullrequestreview-2", "commit": "1f0c..." }]
}
```

- `state` is `OPEN`, `CLOSED`, or `MERGED`. `mergeable`, `merge_state` (GitHub's `mergeStateStatus`), and `review_decision` are the values of GitHub. `review_decision` is empty when the base branch needs no review.
- `merged_at` and `closed_at` are present when the PR is merged or closed.
- `queue_position` counts from 1. It is 0 when the PR is not in the merge queue.
- `behind_base` counts the commits of the base branch that the head does not have. `approvals` counts the reviewers with write access whose last review approves. `comments` counts the review threads that are not resolved.
- `checks` counts the checks of the head commit. `checks.state` is GitHub's summary, empty when the head has no checks. A cancelled or stale check counts only in `total`. `required` counts the checks that the base branch needs to pass before a merge, and `required_passed` counts those that passed. For an `UNSTABLE` PR, the app can write "14 of 14 required checks passed · 2 optional failed".
- `failed_checks` lists each failed check. A GitHub Actions job has its workflow name first. `duration` is in seconds, 0 when GitHub gives no start or end. `required` is true for a required check. `run_id` is the GitHub Actions run of the check, which `loam worktree rerun` runs again. It is left out for a check that is not a job of GitHub Actions.
- `passed_checks` lists each passed check, with the same fields as a failed check. A skipped or neutral check counts as passed, as in `checks.passed`, so the list is as long as `checks.passed`. A check run that GitHub skipped has `skipped` true. The field is left out for each other check. The order is the order of GitHub. A cache row from before Loam stored the passed checks gives an empty list until the next refresh. MCP `list_worktrees` leaves the field out.
- `change_requests` lists the reviews that request changes: the last review of each reviewer with write access, when it requests changes. `id` is the node ID of the review on GitHub. `author` is a login, or `ghost` for a deleted account. `body` is Markdown, and it is empty for a review with only comments on lines. `commit` is the commit that the review is of. It is left out when GitHub gives none, such as for a commit that a force push removed.
- `comment_reviews` lists the reviews of apps that only comment, such as a review bot: for each app whose review can push to the repo, its last review with a body on the head commit, when that review is `COMMENTED`. A review with no body, such as the review that holds a reply on a thread, does not count. A review bot can put a finding in the body, such as a finding on a line outside the diff, which has no thread. The fields are those of `change_requests`.
- `review_threads` lists the review threads that are not resolved, in the order of GitHub, so it is as long as `comments`. `id` is the node ID of the thread, which Loam and a session need to reply on it and to resolve it. `line` is the line in the PR head, 0 when the head no longer has it. `url` is the page of the first comment. `comments` are the first 10 comments of the thread, oldest first, each with `author`, `writer`, `body` (Markdown), and `url`. `writer` is true when the author of the review that holds the comment can push to the repo. When GitHub gives no review for the comment, `writer` is true when the author association of the comment is `OWNER`, `MEMBER`, or `COLLABORATOR`, and false for each other association.
- A cache row from before Loam stored the reviews gives empty `change_requests` and `review_threads` until the next refresh, and so does a row from before Loam stored `comment_reviews` for that list. MCP `list_worktrees` leaves the three out.
- Loam reads one page of 100 checks, 100 reviews, and 100 review threads, to keep to two queries for each repo. `comment_reviews` is of the last 100 reviews. `checks.total` counts every check. The other check counts, `failed_checks`, `passed_checks`, `change_requests`, `review_threads`, and `comments` cover the first 100.
- `behind_base`, `approvals`, `comments`, `checks`, `failed_checks`, `passed_checks`, `change_requests`, `review_threads`, and `comment_reviews` are for an open PR. They are 0 or empty for a merged or closed PR. Each of the lists is always a list, never null.

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
  "remote_branch_deleted": true, "worktree_removed": true, "branch_deleted": true,
  "landed_runs": [], "run_warnings": []
}
```

- `pr` and `stage` are from the refresh before the merge. `changed` and `unpushed` are the local checks of the worktree.
- `methods` lists the merge methods that the repo allows. `default_method` is the method that GitHub offers first: the method that you last used in the repo, else the default of the repo. `merge_queue` is true when the base branch has a merge queue.
- `method` is the method of the land: `--method`, else `default_method`. It is empty with a merge queue, which merges with its own method. `--method` with a merge queue, or a method that the repo does not allow, exits with code 2.
- `ready` is true when no check blocks. `merged` is true when GitHub says that the PR is merged. For a merged PR, `methods` and `default_method` are empty, and `checks` has `work_after_pr` only. `merge_later` is true when GitHub merges later, and when Loam cannot see the merge yet (`merge_note` says why).
- `worktree` has the `land` that the worktree records after the land. It has no `land` after the tidy up of a merge, and after a removal. When the tidy up waits for open panes (step 6), it has the `land` that the land recorded.
- `land_note` says that the worktree recorded a `land` of another PR (see below).
- `landed_runs` are the runs of the worktree that the land landed after the merge, and `run_warnings` says what went wrong on the way. Both are always there. See [Land](#land) under Runs.
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
| `work_after_pr` | `none`, `found`, `unknown` | `found` or `unknown`. Only for a merged PR. `none` means that the work of the worktree is in the merged PR, by the rule of `rm` (see [Worktrees](#worktrees)). `found` means that the worktree has work that the PR does not have. When the local repo does not have `head_oid`, the land fetches it first: `git fetch --no-tags --no-write-fetch-head --no-recurse-submodules origin refs/pull/<number>/head`. The fetch updates no ref. When the fetch fails, Loam cannot tell, and the state is `unknown`. |

- `checking` means that GitHub still checks whether the PR can merge (`mergeable` is `UNKNOWN`). `unknown` means that git could not read the local checks. For `work_after_pr`, it can also mean that the fetch of the PR head failed. Then the message says "Loam could not read the PR head from GitHub. Run git fetch, then land again".
- While GitHub checks, the stage rule keeps the last stage of the PR when it is `conflicts`, `behind_base`, or `blocked` (see [Ship state of worktrees](#ship-state-of-worktrees)). Then the check of that stage blocks as if GitHub had answered.
- `running`, `waiting`, `required`, and `checking` do not block. When GitHub refuses the merge for one of them, its message comes back as exit code 1.

A land runs these steps:

1. It refreshes the PR.
   - A closed PR exits with code 1. Without `--dry-run`, the land clears the `land` that the worktree records, and the message says so.
   - With `--head <commit>` and an open PR, a land that is not a dry run stops when the PR head is another commit: exit code 16 (`not_ready`) with no check in `checks`, and the message "PR #12 has new commits since you looked at it. Look again before you merge". When `--head` is a local commit after the PR head, the message is "PR #12 does not have the commit that you looked at. Look again when GitHub has it, before you merge". It changes nothing and calls no action of gh. The app passes the head of the plan that its Land sheet shows, so a commit that GitHub got after the sheet read the PR is never merged unseen. A dry run and a merged PR ignore `--head`. A value that is not a full commit ID exits with code 2.
   - For a merged PR, the land runs the check `work_after_pr`. With `--dry-run`, it stops there and prints the result. A dry run can fetch the PR head too, because the fetch changes no ref. When the check blocks, the land removes nothing and deletes nothing, and exits with code 16 (`not_ready`). It keeps the `land` that the worktree records, so a land after the work is saved applies its keeps. Else the land skips to step 6.
2. It reads the merge settings of the repo and of the base branch from GitHub.
3. It runs the checks. With `--dry-run`, it stops here and prints the result, also when a check blocks (exit code 0). Else, when a check blocks, it exits with code 16 (`not_ready`).
4. When it removes the worktree right after the merge, it refuses while a pane is open in the worktree, as `rm` does: exit code 1. The app closes the panes first, or passes `--keep-worktree`.
5. It runs `gh pr merge` with the method and `--match-head-commit`, so GitHub refuses the merge when the PR has a commit that Loam did not check. With `--auto`, GitHub merges when the checks pass. With a merge queue, GitHub adds the PR to the queue. Then the land refreshes the PR again.
6. When GitHub says that the PR is merged, the land tidies up. gh can merge a clean PR at once, also with `--auto`, so the tidy up checks the open panes first, unless `--keep-worktree`. With a pane open, it deletes nothing and removes nothing. It records its options in `land`, and `worktree_note` ends with "Close the panes of <worktree>, then run loam worktree land again". Else it deletes the branch on GitHub, unless `--keep-remote-branch` (see below). Then it removes the worktree as `rm` does, unless `--keep-worktree`. A step that fails is a note, and the exit code is 0.
7. When GitHub merges later, the land records its options in `land` on the worktree and keeps the worktree. A later land of a merged PR does step 6. The tidy up clears `land`, also when the worktree stays for another reason.

The delete of the branch on GitHub:

- The land reads the branch first. A branch with commits after the PR head stays.
- A branch that GitHub already deleted counts as deleted: the read gives HTTP 404, or the delete gives HTTP 404, or HTTP 422 with "Reference does not exist".
- GitHub also gives HTTP 422 when it refuses the delete, such as for a protected branch or a ruleset. After another HTTP 422, the land reads the branch again. The branch counts as deleted only when that read gives HTTP 404.
- A branch that stays has `remote_branch_note`, with the reason.

A later land of the same PR applies the keeps in `land`: a recorded `keep_worktree` or `keep_remote_branch` stays a keep, and the flags of the later land can only add keeps. So a land again with no flags finishes a land as its first run said. A `land` with another `pr` than the PR of the branch is stale, and its keeps do not apply. A land clears it, and `land_note` says so. With `--dry-run`, `land_note` says that it is stale, and the land changes nothing. When a check blocks, the message of the error says that the land cleared it.

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

### Runs

A run is one goal that a background Claude Code session (`claude --bg`) works on in a worktree of a plot, until its Done when checks pass and CI passes on its PR. Runs are not in the change log. Each write of a run rewrites `loam.changed`.

```json
{
  "id": "runraaaaab", "plot_id": "k3v9q2mxa7", "worktree_id": "wtreeaaaab", "folder": "/abs/path/of/worktree",
  "title": "Fix the login form", "goal": "The login form works on phones.",
  "done_when": [{ "name": "Go tests", "command": "go test ./..." }],
  "state": "running", "tries": 1, "max_tries": 3, "review_tries": 0, "turns": 2,
  "source": { "kind": "github", "key": "#57", "url": "https://github.com/example/widgets/issues/57" },
  "pr": { "number": 147, "url": "https://github.com/example/widgets/pull/147" },
  "session_id": "c57ef956-3136-4e86-bfde-da8facfe0523", "note": "Try 1 failed: Go tests", "group_id": "", "notes": null, "fixes": "",
  "created_at": "2026-10-02T09:00:00Z", "updated_at": "2026-10-02T09:04:00Z"
}
```

- `state` is one of these:
  - `shaping`: it waits for you to approve its goal and checks.
  - `queued`: it waits for a slot. The run limits or the week's usage hold its session, and `note` says why. A tick starts it when a slot is free. See [Limits, the queue, and usage](#limits-the-queue-and-usage).
  - `starting`: Loam is starting its session.
  - `running`: its session works, or the gate or CI sent failures back.
  - `shipping`: every check passed, and the repo is on GitHub. `loam run tick` pushes the branch, opens the PR, and reads CI.
  - `ready`: it waits for you to land it. Every check passed, and CI passed on its PR, or it has no PR. `note` says which. A review that requests changes can still be open when the review tries are used up, and `note` says so.
  - `stopped`: it used all its tries, or a failure stopped it. A tick also stops a `running` run whose session ended a turn that Loam has no record of (see Ship).
  - `limited`: Claude Code hit a usage limit (Stopped by a limit). It counts no try.
  - `start_unknown`: `claude --bg` did not return in time. The session may exist.
  - `landed`, `cancelled` (you cancelled it with `run cancel`, note "Cancelled by you"), and `skipped` (a recurring run found no work).
- `shaping`, `stopped`, and `limited` need you.
- `tries` counts the failed gates and the CI failures. `max_tries` is 1 to 8, because Claude Code lets a session stop after 8 blocked stops in a row.
- `review_tries` counts the times that Loam sent the review of the PR back to the session, because the review requested changes (see Ship). It is at most 2, and it counts no try.
- `turns` counts the turns that the session ended: the Stop hook adds 1 for each Stop, in any state. It is always there, and it is 0 before the first Stop.
- `session_id` is empty until the SessionStart hook of the session records it. `claude --bg` picks its own session ID. `claude attach`, `logs`, and `stop` take its first 8 characters.
- `pr` is the PR that Loam opened for the run, or the open PR of its branch that Loam found. It is left out before the run ships.
- `source` is the issue of the worktree's link, or the map ticket that `--ticket` names (`kind` `map`, `key` such as `map 135`, `url` the path of the ticket file). It is left out when there is none.
- `group_id` links the runs that one split shape made for one issue, one in each repo (see Shape). It is the ID of the first run of the group. It is always there, and it is empty for a run alone. `run list` and `run status` show it.
- `notes` are the ship notes that Claude wrote when Loam opened the PR of the run (see Ship). It is always there. It is null before Loam opens the PR, and when Claude wrote no notes. One case gives notes that Claude did not write: when the run has no notes and the code review after the last round of the run lets Loam push, the notes hold only `risk`, with the level `high` and the findings of that review in `reasons`. Their `walkthrough` and `where_it_stands` are empty, and `files` is empty (see Code review).
- `fixes` is the ID of the landed run that this run fixes, from `--fixes` of `run start` or `run shape`. It is always there, and it is empty for a run that fixes none. The run metrics count a landed run that a later run fixes as a change failure (see Metrics).

```json
{
  "walkthrough": "The plot panel moves a link by drag. The order goes through the change log, so undo puts it back.",
  "files": [{ "path": "core/internal/store/order.go", "role": "The rule" }, { "path": "core/internal/store/order_test.go", "role": "Tests" }],
  "risk": { "level": "low", "reasons": ["Two files, both in the plan.", "No store change."] },
  "where_it_stands": "Links move by drag. Next: drag a repo.",
  "written_at": "2026-10-02T09:04:00Z"
}
```

- `walkthrough` says what changed and why, in 2 to 4 plain sentences.
- `files` holds each changed file once, in the order that a reviewer should read them. `role` is 1 to 4 words.
- `risk.level` is `low`, `medium`, or `high`. `reasons` are short sentences: Claude's first, then the facts that Loam adds.
- `where_it_stands` is a new text for the Where it stands of the plot: the text that the plot had, moved on by this change. `run land --where-it-stands` sets it.

The gate is the Stop hook of the session. Each time the session ends a turn, Loam runs each check with `sh -c` in the folder, then checks that `git status --porcelain` is empty ("Work committed"). Each of these runs in the sandbox of the run (see Sandbox below). When all pass, the run is `shipping` when the origin of its repo is on GitHub, else `ready`. When one fails, the try counts, unless the gate ran out of time (see below). With tries left, the hook exits 2 and the failures go back to the session as its next prompt. With no tries left, the session stops and the run is `stopped`.

The gates take turns. Each gate holds the gate lock, `gate.lock` in the Loam home, while it runs its checks, so the gates of all the runs of one Loam home run their checks one at a time. Checks that run at once slow each other down past their timeout. A gate that finds the lock taken records the event `gate` "Waits for the gate of another run to end its checks", and tries the lock again every 5 seconds. When it gets the lock, it records "Waited 3m12s for the gate of another run". The time limits are:

- A check has 10 minutes. The wait for the lock does not count toward this timeout.
- A gate has 28 minutes for the wait and every check together. The Stop hook has 30 minutes, and Loam keeps the last 2 to record the result.
- A gate waits for the lock only while the gate has the time that its checks can take: 10 minutes for each check of the run and each rule of the plot, and 1 minute for "Work committed". A run with one check keeps 11 minutes, so it waits 17 minutes at most. When the wait uses that time, the gate runs no check, and it records "Waited 17m for the gate of another run, which left no time for the checks".
- A run whose checks can take more than 28 minutes, such as a run with 3 checks, cannot keep that time with any wait. So it keeps 11 minutes, as a run with one check does, and waits 17 minutes at most. When its checks then run out of the 28 minutes, the gate ran out of time because it waited (see below).

A gate runs out of time when its wait left no time for the checks, or when each check that failed ran out of time. A check runs out of time when it does not end in 10 minutes, when it does not end before the gate runs out of time, or when it does not run because the gate ran out of time. Its `check` event names the check and the limit, such as "Checks did not end in 10m". The session cannot fix this, so no try counts:

- The first such gate blocks the stop with a short prompt: "Loam gate: Checks did not end in 10m. That is not a failure of your work, so no try counts. End your turn now and change nothing: Loam then runs the checks again." The run stays `running`, with the note "Checks did not end in 10m. No try counted, and Loam runs the checks again".
- The second gate in a row whose checks ran out of time stops the run. The run is `stopped`, with the note "Checks did not end in 10m, 2 gates in a row. No try counted".
- A gate that ran out of time because it waited for the lock never stops the run. That is a gate whose wait left no time for the checks, or a gate that waited, for any time, and then ran out of the 28 minutes during a check (not of the 10 minutes of the check itself). After a wait, the gate cannot know if the checks fit the 28 minutes. Only a gate that did not wait counts a run out of the 28 minutes as a gate whose checks ran out of time. A run whose checks take more than 28 minutes on their own counts it at its first gate with no wait, and the limit of blocked stops below stops it in any case. It always blocks the stop with the prompt, with no try, and it does not change the count of the gates whose checks ran out of time. The lock gives no turn order: each waiting gate tries it every 5 seconds, so a gate that arrives later can take it first. So the wait comes from the gates of other runs, not from the work of the session. The turn limit still holds for a run that waits out again and again.
- A gate that does not run out of time starts the count again, and so does each resume of the session by Loam: your notes (`run send-back`), a CI failure, a code review, and a PR review that go back to the session, also from the queue. A gate where one check ran out of time and another check failed for another reason counts the try as usual, because the session can fix that failure.
- The turn limit (see [Limits, the queue, and usage](#limits-the-queue-and-usage)) applies to such a gate as it does to a failed gate.
- Claude Code lets a session stop after 8 blocked stops in a row, and the run would then stay `running` with no session at work. A gate that runs out of time blocks the stop with no try, so the tries alone do not keep the blocks under that limit. So the gate blocks at most 7 stops in a row, of any kind, and at the next one it stops the run: `stopped`, with the note "Stopped after 7 blocked stops in a row, the most that Claude Code allows. The last gate: <note>". A stop that the gate lets end, and each resume of the session by Loam, starts the count again.

A full check can take minutes, and the gate runs it anyway. So the first prompt of a run with checks tells the session to run only the fast tests of the code that it changes, such as the tests of one package, and not to run the checks itself. Each prompt that sends work back to the session of a run with checks says this again: a failed gate, a code review, a PR review, and your notes. The gate does not run the checks of CI, so the prompt of a CI failure tells the session to read the logs and run only the tests that failed in CI, such as one test or one package, not the whole job. With checks, it also tells the session not to run the Done when checks itself.

| Command | Output |
| :- | :- |
| `loam run start <plot> --title <text> [--goal <text>] [--check <name>=<command>]... [--worktree <name>] [--repo <repo>] [--base <branch>] [--link <link-id or URL> \| --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>] [--approve-setup] [--fixes <run>]` | `{ "run": {...}, "worktree": {...} }` |
| `loam run list [<plot>]` | An array of runs, newest first. It is `[]` when none exists. |
| `loam run events [--since <time>] [--plot <plot>]` | `{ "events": [{ "run_id": "...", "plot_id": "...", "run_title": "...", "at": "...", "kind": "state", "detail": "running" }] }` |
| `loam run status <run>` | `{ "run": {...}, "events": [{ "id": 1, "run_id": "...", "at": "...", "kind": "state", "detail": "running" }], "failed_checks": [{ "name": "Go tests", "command": "go test ./...", "passed": false, "exit": 1, "output": "...", "output_cut": false }], "code_review": { "findings": [{ "severity": "major", "file": "core/app.go", "line": 42, "text": "..." }], "more": 0 } }`. `kind` is `state`, `try`, `check`, `gate`, `linear`, `ship`, `ci`, `conflict`, `code_review`, `review`, `note`, `land`, `shape`, `draft`, `followup`, or `git`. See "Run status" below. |
| `loam run cancel <run>` | `{ "run": {...} }`. Loam stops the session, and the run is `cancelled` with the note "Cancelled by you". A `cancelled` run cannot go back to its session. A run that has ended stays as it is. A `queued` run is cancelled too. |
| `loam run stop <run>` | The old name of `run cancel`, hidden from the help. The JSON is the JSON of `run cancel`. It prints "loam run stop cancels the run. Use loam run cancel." to stderr, also with `--json`. The run is `cancelled`, not `stopped`. |
| `loam run tick` | `{ "runs": [...], "warnings": ["..."] }`. `runs` are the runs that the tick moved or started. Both are `[]` when none. |

**Run status.** An event can hold data beside its `detail`. Each field is left out for an event of another kind, and for an event from before Loam stored it:

- `check`: the result of the check of a `check` event: `{ "name", "command", "passed", "exit", "output", "output_cut" }`. `exit` is -1 when the check did not run or did not end. `output` is the output of a failed check, stdout and stderr together, at most 32768 bytes from its end, from the start of a line when it can. `output_cut` is `true` when the output was longer. A check that passed keeps no output.
- `code_review`: what the review of a `code_review` event found: `{ "findings", "more", "round", "needs_you" }`. `findings` holds each finding of the review, most severe first, also the Minor ones that do not go to the session, each `{ "severity", "file", "line", "text", "needs_you" }` as Loam cleaned it (see Ship). `round` is the round of the run whose findings went back to the session, and `needs_you` is `true` when the review stopped the run for you. A finding has `needs_you` only when it gives a reason. The other fields are not there when they are 0 or false. It keeps at most 100 findings, and `more` counts the rest. A review that found no issues has an empty list. A review that did not run or was off has no `code_review`.

`failed_checks` are the `check` results that failed in the last gate of the run, in the order that they ran. The last gate is the last block of `check` events. The list is empty when that gate passed, when the run has no gate, or when its events are from before Loam stored the results. `code_review` is the `code_review` of the last `code_review` event of the run, or `null`.

The text of `run status` shows the run, then the code review rounds that the run used, such as "Code review: 3 of 5 rounds" (no line before the first review of the run), and then its history. Under the history, it shows each failed check of the last gate with its name, its exit code, and the last 20 lines of its output, and then each finding of the last code review with its severity, its file and line, its text, and "(needs you: <reason>)" when it has one. The JSON has the whole stored output.

`run events` lists the events of every run of every plot, or of the runs of one plot with `--plot`, newest first, at most 200. `--since` takes an RFC 3339 time and lists only the events after it. A time that does not parse gives exit code 2. `run_title` and `plot_id` are those of the run. `kind` is as in `run status`. The Today screen shows the list as "While you were away".

`run start` uses the worktree that `--worktree` names, or makes it. With no `--worktree`, it makes a worktree with a name from the key of the link or the ticket, and the title. With no `--repo`, a new worktree is in the repo of the plot whose origin the `--link` is a GitHub issue of, else in the main repo. `--repo` always wins. `run shape` picks its repo in the same way. A run has `--link` or `--ticket`, not both (exit code 2). It refuses, with exit code 1, a folder that Claude Code does not trust: a background session cannot show the trust prompt. In git, Claude Code trusts a worktree when it trusts the main checkout of the repo. A setup command that you have not approved gives exit code 2 (`invalid`); `--approve-setup` approves it. When `claude --bg` fails, the run is `stopped` with the output in `note`, and the command exits 0. When the sandbox rules cannot be built, or the git config is one that the run can write (see Sandbox), the run is `stopped` with the reason in `note`, and the command exits 1. When no slot is free, the run is `queued` with the reason in `note`, and the command exits 0 (see [Limits, the queue, and usage](#limits-the-queue-and-usage)).

`--fixes` takes the ID of a run of the same plot that is `landed`. Another run gives exit code 2 (`invalid`), and a run that does not exist gives exit code 1. Nothing is made. With no `--repo`, a new worktree goes in the repo of the run that it fixes: the repo of its draft, else of its worktree, else its folder. When that repo is no longer in the plot, the run takes the usual repo. `run shape` takes `--fixes` too, and each run of a split fixes the same run.

The settings file of a run names the Loam home of the store that holds the run. Claude Code runs each background session under one supervisor, which keeps the environment of the first `claude --bg` call. Each session and each hook gets that environment. So the command of each run hook is `LOAM_HOME=<home> <loam> run hook <run>`, with the home and the loam path in shell quotes. The `env` of the settings sets `LOAM_HOME` to the home, so the `loam` calls of the session use the same store. It also sets `LOAM_PANE_SOCKET` to an empty value, so that no run session gets the socket of the pane that started the supervisor. An empty `LOAM_PANE_SOCKET` means no pane.

#### Sandbox

The session of a run works in the Bash sandbox of Claude Code (Seatbelt on macOS). The settings file of the run holds the `sandbox` block. The sandbox covers Bash and the processes that Bash starts. The Read and Edit tools, the hooks, and the MCP servers work outside it.

- Read: the sandbox denies the home folder, then allows the folder of the run, its git folder (the main checkout's `.git` for a worktree), the repos of the plot, the local links of the plot, `~/.gitconfig`, the `config`, `ignore`, and `attributes` files of `~/.config/git`, each config file of the system, global, and local scopes that `git config --list --no-includes --show-origin` names for the run folder, the files that those include (see Git config includes below), and the caches and toolchain folders of each stack preset, and the read and write paths that you add (see below). Paths outside the home folder stay readable. Loam leaves out a repo or a link that would open the home folder: the home folder, a folder above it, the root, a credential path, a path in one, or a folder that holds one, such as `~/.config` or `~/Library`. The compare ignores case, as macOS folders do. A run whose folder is such a path does not start. The git folder is the `.git` folder of the repo of the plot whose `.git` or `.git/worktrees/<name>` the `.git` of the run folder names. `worktrees` and `<name>` must be folders, not links, because the run can write the git folder and put a link there to another repo. Loam does not ask git for it, because git follows a `commondir` file in the git folder, which the run can write, to another repo. For the same reason, Loam runs `git config` with that git folder, and it leaves out the worktree scope: the run can write `config.worktree`, and an include there would name any file. When the git folder of the run is in no repo of the plot, or the run works in a repo of the plot whose `.git` is not a folder, the run does not start either. In each case, the run is `stopped` with the reason in `note`.
- Git config includes: Loam follows each `include.path` and `includeIf.*.path` of those config files, to the 10 levels that git follows. The sandbox reads the file of each entry, whatever its condition. Git opens the file of a `hasconfig` condition also when the condition does not hold, and a denied file would stop every git command of the run. The run can change its branch, so an `onbranch` condition can hold later in the run. Loam allows the file that the system opens for the path as git builds it: a relative path from the folder of the name of the config file, and `~/` from home. Git does not clean the path, so the system follows each link before a `..`, and Loam does the same.

  Loam does not follow the includes of a file that the sandbox refuses. It leaves out a folder. The sandbox text of the first prompt has a line for each of these cases, so that the session says why git stops:
  - an include file that exists and that the sandbox refuses, such as a file in a credential folder.
  - a file with includes that the sandbox refuses.
- Git config that the run can write: git config reaches the git that Loam runs outside the sandbox, so a run with such a config does not start. Loam makes the same check before each resume, and when the gate builds the rules. At a start, the run is `stopped` with the reason in `note`, and `run start` exits 1. At a resume, the run is `stopped` with the reason in `note`, and the session gets no prompt. At the gate, the run is `stopped` with the reason in `note`, no check runs, and no try counts. The check uses no deny rule. Loam refuses in these cases:
  - The target of an include is at or below a write path of the run. The error names the config file, the include, and the write path, and it says to remove the include. A write path here is each path of the Write list below, also a path that `denyWrite` covers, and each temporary folder (`$TMPDIR`, the user temp and cache folders of `getconf`, and `/tmp`). Loam walks the include chains of the system, global, and local config, and it counts each `include.path` and each `includeIf.*.path`, whether its condition holds now or not. It also walks a file that the sandbox refuses, because git outside the sandbox reads that file. A target counts whether it exists or not, and a folder counts, because the run can replace it with a file.
  - A config path of the system or global scope is at or below a write path, or the local config is a link. The run could then write the config with no include. Loam checks each path that git can read, whether it exists or not, because the run can make or fill the file: `GIT_CONFIG_SYSTEM` or the system path that git names, and `GIT_CONFIG_GLOBAL` or both `~/.gitconfig` and `git/config` in `XDG_CONFIG_HOME` (by default `~/.config`).
  - `extensions.worktreeConfig` is on in the local config. With it, git reads `config.worktree` in the git folder, which the run can write. The error names the command that turns it off: `git config --file <git folder>/config --unset-all extensions.worktreeConfig`. Git reads this setting only from the local config, and not through an include. With the setting off, git does not read `config.worktree`, and `denyWrite` stops the run from writing the local config.
  - The `commondir` file in the metadata folder of the worktree of the run, or in the git folder of the repo, names a folder other than the git folder of the repo, or the metadata folder has no such file. Git takes the config of the folder that the file names, so the file can turn on `extensions.worktreeConfig` and give git any config. Git in the main checkout reads the file in the git folder, so a run in a worktree can reach that git too. Loam reads the value as git does, with each link before a `..`. See the known limit below.
  - Loam cannot tell: git cannot read a config file or a file that an include names, an include path starts with `~user/` or `%(`, a path follows too many links, or git did not name the includes in 10 seconds.

  Loam compares as a volume of a Mac does. It follows each link in the part of the path that exists, also a link to a file that does not exist, and it takes a `..` from where the walk is. It takes the rest of the path by the text. It then compares without regard to case and Unicode normalization. A path through a write path counts even when it ends outside, because the run can change a link or a folder on the way. On a volume that tells case or Unicode forms apart, two such names are two files, and Loam still refuses.
- Write: the folder of the run, its git folder, the private folder of the run (see below), the caches of each stack preset, the write paths that you add, and the temp folder of the user (`getconf DARWIN_USER_TEMP_DIR`). Foundation and `mktemp` take that folder and ignore `TMPDIR`, so most Swift tests and many scripts write there. `denyWrite` denies `xcrun_db*` in it (see Gate below), and `permissions.deny` denies it to the Edit tool. The pattern covers the cache and the copy of it that a shim that misses the cache writes beside it, `xcrun_db-<random>`, before it renames the copy onto the cache. With only the cache denied, the rename fails, and each run of such a shim leaves a copy of some MB. With the pattern, the shim writes no copy and runs the tool. A shim that cannot fill a cache looks up its tool on each run, which takes 2 to 10 seconds. So the session gets its own cache, as the gate does (see Gate below):
  - The private folder of the run is `run-temp/<run-id>` in the Loam home. Before each start and each resume of the session, Loam removes what is there, makes a new folder, and writes a copy of your cache in it as `xcrun-cache`. The rules allow Bash to read and write this folder, by the real path of the folder that holds it. When a link is in its place, the rules leave it out. Loam removes the folder when the run lands and when you cancel it. A `stopped` run keeps it, because a send-back can resume its session.
  - The SessionStart hook of the run appends `export xcrun_db=<private folder>/xcrun-cache` to the file in `CLAUDE_ENV_FILE`. Claude Code applies that file only to the Bash commands of the session, and each one works in the sandbox. The settings `env` does not set `xcrun_db`: Claude Code, its hooks, and its MCP servers get that `env`, and they work outside the sandbox.
  - The rule: no process outside the sandbox reads a file that the session writes. A shim runs each path that its cache names, so a cache that the session wrote would make the next git outside the sandbox, of Loam or of you, run a file of the session. A process outside the sandbox never gets this `xcrun_db`, so it keeps your cache.

  Claude Code also allows its temporary folder and each `--add-dir` folder. So a run session adds only the plot folder, which holds the seed, and `denyWrite` denies it. `denyWrite` also denies `hooks` and `config` in the git folder, and the `.git` file of a worktree, which names its git folder. Git runs a hook or a config command outside the sandbox, in the next git command of Loam or of you. So the session cannot set an upstream or add a remote: Loam pushes the branch. A denied path wins over an allowed folder that holds it. A run session does not add the other repos or the local links: Bash reads them through `allowRead`, and the Read tool reads them in auto mode. The `CLAUDE.md` of another repo does not load in a run.
- Network: only the hosts of the stack presets and the hosts that you add (see below). `strictAllowlist` refuses any other host with no prompt, because nobody answers the prompts of a background session. The block sets `allowLocalBinding`, so a test can start a server. Bash can then listen on any address, `0.0.0.0` too, and a device on the network of the Mac can connect to that server while it runs. `allowUnixSockets` lets Bash bind and connect a unix socket only in the temp folder of Claude Code, `/tmp/claude-<uid>`, which is `TMPDIR` in Bash. Not `/tmp`, which holds the socket of the launchd SSH agent. `allowMachLookup` names `com.apple.trustd.agent`: Go and other tools on macOS check a TLS certificate through trustd, and with no lookup of it, each HTTPS fetch fails. The first prompt of every run tells the session not to work around a command that the sandbox denies.
- `failIfUnavailable` stops a session that has no sandbox, and `allowUnsandboxedCommands: false` ignores a command's request to run outside it.
- `permissions.deny` denies the Read and Edit tools the credential paths: `~/.ssh`, `~/.gnupg`, `~/.config/gh`, `~/.config/gcloud`, `~/.config/op`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/Library/Keychains`, `~/.netrc`, `~/.git-credentials`, `~/.config/git/credentials`, `~/.claude.json`, `~/.cargo/credentials.toml`, `~/.npmrc`, and `~/.pypirc`. It also denies the Edit tool, which covers the Write tool, each `denyWrite` path.
- Known limit, the shared git folder: a worktree keeps its index, `HEAD`, and refs in the git folder of the repo, so the sandbox lets the run write that folder. The metadata of every other worktree of the repo is in the same folder, in `worktrees/<name>`, and the sandbox does not show the folders of those worktrees. So `git worktree prune` in a run takes each other worktree as gone and deletes its metadata, and a `git gc` or a change to another ref can change the work of another worktree. The first prompt of each run, and the sandbox text of a run in a worktree, tell the session not to run `git worktree add`, `remove`, or `prune`, or `git gc`, and not to change a ref other than its own branch. For a base comparison, the session uses `git show <rev>:<path>` or `git archive <rev> | tar -x -C <temp folder>`.

  The same folder holds its own `commondir` file and the `commondir` file of each worktree, and the rules of Loam do not deny them. A check of the gate can write them. Loam finds a changed file of the worktree of a run, or of the git folder of the repo, when it next builds the rules: at a start, at a resume, and at the gate. Git that Loam runs between those points, such as in a tick or a land, reads the config of the folder that the file names. So does git that you run. Loam does not check the `commondir` file of a worktree that no run works in.

  Before Loam runs git in the worktree of a run (in a tick, a land that is not a dry run, a resume of the session, and the gate), it checks that git knows the worktree. When the metadata folder that the `.git` file of the worktree names is gone, and the folder and its `.git` file are there, Loam rebuilds the metadata on the branch of the run. It writes `gitdir` (the path of the `.git` file of the worktree), `commondir` (`../..`), and `HEAD` (`ref: refs/heads/<branch>`) in `<git folder>/worktrees/<name>`, then runs `git reset -q` in the worktree. The reset rebuilds the index and leaves the files, so uncommitted changes stay, unstaged. A `git` event of the run says so, and the work goes on. Loam holds a lock in the Loam home while it rebuilds, which no run can write, so a second Loam process waits for the rebuild and then finds the metadata there. When the gate cannot make the metadata ready for such a reason, for example because a rebuild holds the lock for more than 30 seconds, it runs no check and counts no try, as when it waits out the gate lock, and the checks run at the next stop. As for the sandbox, Loam takes the `.git` folder of the repo of the worktree, and does not ask git for it. Loam does not rebuild when the branch is gone, or when the `.git` file names a folder outside `<git folder>/worktrees`: the run is `stopped`, and its `note` names the folder. Loam does not rebuild the metadata of a worktree that no run works in.

You can add paths and hosts to the sandbox, for a stack that has no preset or for a toolchain folder such as `~/.nvm`. There are two scopes. The machine scope holds for the runs of every plot. The plot scope holds for the runs of one plot. Each scope has three lists: `read`, `write`, and `hosts`. They are stored, not in the change log, and Loam reads them each time it starts or resumes a session. So a change holds for the next new session of a run, and for the next prompt that Loam sends to a session (see Ship).

```json
{ "plot_id": "k3v9q2mxa7", "read": ["~/notes"], "write": ["~/Library/Caches/Loam"], "hosts": ["*.example.org"] }
```

| Command | Output |
| :- | :- |
| `loam run sandbox [<plot>] [--read <path>]... [--write <path>]... [--host <host>]...` | `{ "sandbox": {...} }` |

- With no plot, the command works on the machine scope, and `plot_id` is `""`. With a plot, it works on the plot scope.
- With no flag, the command prints the settings. A flag sets the whole list of its kind and leaves the other lists. Loam applies the flags in one write, and checks only the lists that a flag names, so a stored item that is refused today does not block a change of another list. Repeat a flag to give more than one item. An empty value (`--read ""`) empties the list. The command prints the settings after the change.
- A path is absolute or starts with `~/`. Loam cleans it and writes a path below home with `~/`. A write path is also a read path in the rules. Loam refuses a path that opens the home folder: the home folder, a folder above it, the root, a credential folder (the paths in `permissions.deny`), or a folder that holds one, such as `~/.config` or `~/.cargo`. It also refuses `~/.loam`, `~/.claude`, and the Loam home when `LOAM_HOME` moves it, because a run that wrote there could change its own settings. A write path lets a run write everything below it, including the `hooks` and `config` of a git checkout below it, which git runs outside the sandbox. So give a narrow folder, not one that holds your checkouts. It also refuses a path with a glob character, a quote, a backslash, or a control character.
- A host is a DNS name with at least two labels, or `*.` and such a name. Loam writes it in lower case. It refuses `*`, `*.com`, `localhost`, an IP address, a URL, and a name with a port.
- A refused item exits 2 and stores nothing. An item that fails the checks while a run starts, because an older version wrote it, is left out of the rules.
- Only you set these, with this command and the app. No MCP tool reads or writes them, so a run session cannot widen its own sandbox. Deleting a plot deletes its plot scope.

A stack preset applies when a repo of the plot has its file at the root or one folder down:

| File | Caches (read and write) | Toolchain (read) | Hosts |
| --- | --- | --- | --- |
| `go.mod` | the module cache (`GOMODCACHE`, else the first `GOPATH` entry, else `~/go`, then `pkg/mod`), the build cache (`GOCACHE`, else `~/Library/Caches/go-build`), the checksum database cache (the first `GOPATH` entry, else `~/go`, then `pkg/sumdb`), `~/Library/Application Support/go/telemetry`, and `~/Library/Caches/golangci-lint` | | `proxy.golang.org`, `sum.golang.org`, `vuln.go.dev` |
| `Package.swift` | `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm` | | |
| `ghostty.pin` | | `~/Library/Caches/Loam/ghosttykit` | |
| `package.json` | `~/.npm` | | `registry.npmjs.org` |
| `Cargo.toml` | `~/.cargo/registry`, `~/.cargo/git` | `~/.cargo/bin`, `~/.rustup` | `crates.io`, `index.crates.io`, `static.crates.io` |
| `pyproject.toml`, `requirements.txt` | `~/Library/Caches/pip` | | `pypi.org`, `files.pythonhosted.org` |

The `ghostty.pin` preset is for the Loam repo. `scripts/build-ghosttykit.sh --link-only` links `app/vendor` to the GhosttyKit cache, and the gate builds the terminal and the driver from it. The run only reads the cache, so it cannot change the GhosttyKit that an install builds with. The preset leaves out the rest of `~/Library/Caches/Loam`, which holds Zig and the ghostty source, and it does not follow `LOAM_CACHE`.

SwiftPM runs a manifest in a sandbox of its own, and a sandbox cannot start inside another one. So the first prompt of a run with a `Package.swift` repo tells the session to pass `--disable-sandbox` to `swift build`, `swift test`, and `swift package`. A compact can drop the first prompt, so the SessionStart hook prints the note again after a compact, with the seed. SwiftPM reads no environment variable for this.

Loam resolves each path through its symlinks, because the sandbox matches real paths. Before it starts a session, Loam checks that `/usr/bin/sandbox-exec` is an executable file. It does not run it, because a nested sandbox fails, as in the Bash of a run. When the file is missing, the run is `queued` with `Waits for the sandbox: <reason>` in `note`, and `run start` exits 0. A tick with no sandbox starts no session, a resume too, and writes a note only when it changed. A resume passes the sandbox of the run again (see Ship), so it waits like a new session. A send-back or a CI failure that finds no sandbox stops the run, with the reason in `note`. A sandbox that fails to start stops the session (`failIfUnavailable`), and the run is `stopped` with the output in `note`.

**Gate.** The Stop hook works outside the sandbox of the session, and the checks run code that the session wrote. So the gate runs each check of the run, each rule of the plot, and "Work committed" as `sandbox-exec -p <profile> sh -c <command>` in the folder of the run. The profile is a Seatbelt profile of the same rules. In a profile, the last rule that matches wins, so the rules come in this order:

1. Other processes: deny `lsopen`, `appleevent-send`, the Mach services of Launch Services, Apple Events, CoreServices, and the keychain (`com.apple.SecurityServer`, `com.apple.securityd.xpc`), and each signal to a process outside the sandbox. So a check cannot have an app, a script that Launch Services opens, or the keychain act for it outside the sandbox. The rest of the profile starts from `(allow default)`.
2. Network: deny all, so a check uses the caches that the session filled, and the hosts of the stack presets do not apply. Then allow loopback: a check can start a server and connect to `localhost`, as the test servers of Go's `httptest` do. So a check can reach any TCP service on `localhost`, and it cannot connect to any other host. Seatbelt checks a bind as an inbound operation, and it cannot tell a bind to `localhost` from a bind to `0.0.0.0` or `::`. So while a check runs (10 minutes at most), a server that it starts on `0.0.0.0` can take a connection from another host on the network. Then allow the unix sockets below each path of `allowWrite` and the folder of the gate, and no other unix socket, such as the SSH agent or the Docker socket, which act as you. The temp and cache folders of the user hold no sockets of a check, because other processes of yours keep sockets there, such as the pane sockets of Loam and the diagnostics socket of a .NET process, which can load code into it. `/private/tmp` holds no sockets of a check either, because it holds the socket of the launchd SSH agent. Seatbelt matches the real path of a socket, so a link to another socket does not open it.
3. Read: deny the home folder, then allow each path of `allowRead` and the temp folders of the gate. Allow `file-read-metadata` everywhere, because git reads the metadata of each folder above the repo. Metadata gives names and sizes, not the content of a file.
4. Write: deny all, then allow each path of `allowWrite`, the temp folders of the gate, `/private/tmp`, and `/dev`. The temp folders are the folder of the gate, `TMPDIR` of Loam when it is set, the temp folder of the user (`getconf DARWIN_USER_TEMP_DIR`), where macOS `mktemp` makes its files, and the cache folder of the user (`getconf DARWIN_USER_CACHE_DIR`), where clang and swift keep their module caches. Each is one folder, by its real path, not all of `/var/folders`.
5. Deny each `denyWrite` path last, so a denied path wins over an allowed folder that holds it. Also deny `xcrun_db` in each temp folder. The xcrun shims, such as `/usr/bin/git`, keep the path of each tool there, and they run that path with no check. A check that wrote it could make the next git outside the sandbox, of Loam or of you, run a file of the check. The deny also stops a hard link to the file, and a rename onto it or of it away. So the checks of a gate get their own cache, a copy of yours: Loam sets `xcrun_db` to a file in the folder of the gate. Only the processes of the sandbox get this variable. Without it, a shim that misses the cache prints an error on each run of the tool.

Loam escapes each quote, backslash, and control character in a path, so no path can change the profile. Loam passes the profile inline, with `-p`, and writes no file, so no check can change the profile of the next check. The profile holds paths only, and it shows in `ps` only until `sandbox-exec` starts `sh`. A profile longer than 256 KiB fails the gate, because macOS limits the arguments and the environment of a process together to 1 MiB.

The folder of the gate is `/tmp/loam-gate-<random>`, with mode 0700. Loam makes it for each gate, gives it to each check as `TMPDIR`, and removes it after the gate. `/tmp` keeps the path of a socket in it short. Each check also gets `GOPROXY=file://<module cache>/cache/download`: the profile denies the network, and `go run` of a module at a version asks the proxy if the module is deprecated, also when the module is in the cache. So Go takes each module that the session fetched from the cache.

When `sandbox-exec` is not an executable file, when the rules fail (such as when the git folder of the run is in no repo of the plot), when the profile is too long, or when `sandbox-exec -p <profile> /usr/bin/true` fails (such as in a process that is already in a sandbox), no check runs either. Each check fails with exit -1 and the reason in its output, and the run is `stopped` with "Loam did not run the checks, because it could not sandbox them: <reason>" in `note`. No try counts, because the session cannot fix the sandbox.

SwiftPM sandboxes its manifest, and that sandbox cannot start in the sandbox of a check. When a check fails and its output has `sandbox_apply: Operation not permitted`, its failed log gets one more line: pass `--disable-sandbox` to `swift build`, `swift test`, and `swift package`. Loam does not change the commands of a check.

#### Ship

`loam run tick` moves on each run in `shipping`. A tick that waits on GitHub changes nothing, so the app runs it often while a run ships. Only one tick runs at a time: a second one prints the empty result at once. For each run, the tick does the first step that applies:

1. The run's worktree is gone, and the run has no `pr`, or the origin is not on GitHub: the run is `ready`, and `note` says why. A run that has a `pr` and has lost its worktree (for example after `loam worktree land` removed it) reads its PR by number with `gh pr view <number> --repo <owner/name> --json state,number`. Merged: the run is `landed`, as in step 2. Closed: the run is `stopped`. Open: the run is `ready`, and `note` says "The worktree is gone. Merge #12 on GitHub, or cancel the run". gh missing or signed out makes it `ready` too, with the error in `note`. The worktree is gone only when the store has no record of it: a store that cannot read the record, such as a busy store, is a warning, and the run waits for the next tick. `run land` exits with that error.
2. GitHub has the run's PR merged: the run is `landed`, with a `land` event, and its Linear issue moves to Done. Closed: the run is `stopped`.
3. An open PR of the branch that is not the run's PR: it becomes the run's PR (event `ship`, "Found #12, the open PR of the branch"). For a Linear issue, Loam attaches the PR to it, as for a PR that Loam opens (see step 4). A run that left `shipping` while gh opened its PR gets no event and no attach for that PR: a later tick finds it here. A run with no `notes` then takes the notes of its saved PR text.
4. The head of the worktree is not the PR head: the tick runs the code review of the head (see Code review below). When the review lets Loam push, the tick runs `git push origin <head>:refs/heads/<branch>` when `origin/<branch>` is not the head. It pushes the commit that the review read, so a commit that the branch gets during the review waits for the next tick. Then the branch tracks `origin/<branch>`, as with `git push -u`. When git cannot set that, the push has happened, and the tick gives a warning. A failed push stops the run with the output in `note`. With no PR, it runs `gh pr create` with the title of the run, the base of the worktree, and a body with the goal, the Done when checks, and the issue (`Closes #57` for a GitHub issue, the key, such as `Linear: ENG-523`, for a Linear issue). With a PR template in the worktree, the body comes from the template instead (see below). For a run of a group, the body has one more line with the repos of the other runs of the issue, such as "The issue also has runs in example/docs." A repo on GitHub is `owner/name`, and another repo is its folder name. A cancelled run does not count. It names no local path and no Linear URL, because the repo can be public and the Linear workspace private. The events are `ship`: "Opened #12", or "Pushed the fix to #12" after a failed CI or a send-back. For a Linear issue, Loam attaches the PR to it (event `linear`), when that update to Linear is on (see Linear). A failed attach is a warning. The run gets its `notes` in the same write as its `pr`.
5. The merge state of the PR head, before CI:
   - `mergeable` is `CONFLICTING`: the run does not become `ready`, also when CI passed. The session cannot fetch, so Loam runs `git fetch --no-tags origin +refs/heads/<base>:refs/remotes/origin/<base>` in the run folder first, with `<base>` the base branch of the PR. A fetch that fails is a warning, and the next tick tries again. Then Loam sends the session back as for a CI failure (see step 6), with a prompt that names the base branch and the files that conflict, from `git merge-tree --write-tree --name-only`. The prompt tells the session to run `git merge origin/<base>`, to keep the behaviour of both sides in each conflict, to run the tests of the code that the merge changed, and to commit the merge. The run is `running` (or `queued`), with the `note` and the `conflict` event "#12 conflicts with main. Loam sends the run back to merge main (conflict send-back 1 of 2)". No try and no review try counts. The next gate that passes ships the merge to the same PR.
   - Loam sends one conflict send-back for each PR head, and at most 2 in a row. When the PR still conflicts on the head that went back (the session made no merge commit), or after 2 send-backs in a row, the run is `stopped`. The `note` and the `conflict` event name the files that conflict, for you to merge: "#12 conflicts with main after 2 conflict send-backs in a row. Merge main into the branch yourself. The files that conflict: core/app.go", or "#12 conflicts with main, and the session made no merge commit after the conflict send-back. Merge main into the branch yourself. ...". When `HEAD` in the run folder is not on the branch of the run, a merge there would not reach the PR, so the run is `stopped` with no fetch: "#12 conflicts with main, and the run folder is not on <branch>. Check out <branch>, then merge main into it yourself". A PR head that is `MERGEABLE` starts the count again, and so does a new PR of the run (step 3). The count is not in the JSON.
   - `mergeable` is `UNKNOWN`, because GitHub still computes it: nothing changes, and the next tick reads it again.
6. CI on the PR head:
   - No checks: the run waits 3 minutes after the push, then is `ready` ("No CI ran on #12"), unless the review of the PR requests changes (see Reviews below).
   - The first failure on a PR head: Loam runs the failed jobs again once, with `gh run rerun <run ID> --failed --repo <owner/name>` for each GitHub Actions run of a failed check, so a flaky job costs no try. GitHub runs the failed jobs of a run again only when all its jobs have ended, and the PR does not say which run a check that runs is in. So while a check of the head still runs, the run waits in `shipping`, and a later tick runs the failed jobs again. No try counts, and the run stays `shipping`, with a `ci` event and the `note` "CI failed on #12: ci / test. Loam runs the failed jobs again (run 9001)". Loam keeps the head on the run, so it runs the jobs of a head again at most once, and a new head, such as a fix, gets its own rerun. A failure on that head in the minute after the rerun waits, because GitHub can show the failed jobs of the first attempt for a moment. Loam runs nothing again when a failed check is not a job of GitHub Actions, because that check fails again on the same head. A rerun that GitHub refuses, such as of a run that is gone, is a `ci` event ("CI failed on #12: ci / test. Loam could not run the failed jobs again: <why>"), and the failure goes back to the session as below. A rerun that cannot reach GitHub, or that GitHub refuses for its rate limit, waits for the next tick.
   - A failed check that Loam does not run again: the try counts. A second failure on the same head says "CI failed twice on #12" in `note`, in the `ci` and `try` events, and in the prompt, which also says that Loam ran the failed jobs again. With tries left, the run is `running` (or `queued`, with the prompt, when no slot is free) and Loam sends the session a prompt with each failed check and the last 60 lines of its failed log (`gh run view <id> --log-failed`). The prompt tells the session not to change a test outside the goal of the run to make CI pass: when the failure is outside its change, the session says so in its last message, changes nothing, and ends its turn. Loam keeps the head whose failure went back to the session. When CI fails again on that head, the session made no commit for the failure: the run is `stopped`, with a `ci` event and the `note` "CI failed again on #12: ci / test. The session made no commit for the failure. Read its last message, then send the run back or cancel it". No try counts. Loam runs `claude stop` and then `claude --bg --resume <session ID>` with the options of the start: `--name`, `--permission-mode auto`, the model and effort of the run defaults, `--add-dir` of the plot folder, and `--settings` with the sandbox, the deny rules, and the run hooks, written again from the rules of the run as they are now. `claude --resume` keeps none of these: with no flags, the session works with no sandbox and no run hooks, so no gate runs. When Loam cannot write the settings, it sends no prompt, and the run is `stopped`. The next gate that passes ships the fix to the same PR. With no tries left, the run is `stopped`.
   - Checks that run or wait: nothing changes.
   - All passed: the run is `ready` ("CI passed on #12: 14 of 14 checks"), unless the review of the PR requests changes (see Reviews below).

**Reviews.** When CI passed or no CI ran, and `review_decision` is `CHANGES_REQUESTED`, Loam sends the review back to the session as for a CI failure. It does this only when it has something to send: a review in `change_requests` that it has not sent, or a thread in `review_threads`. A thread with no change request does not stop the run.

A review in `comment_reviews` whose body has a Critical or Major finding goes back in the same way, also when `review_decision` is not `CHANGES_REQUESTED`. A review app can put the severity in the header of each finding, in one of three forms: an emoji, such as "_⚠️ Potential issue_ | _🟠 Major_", an icon, such as "**<picture><img src=\"https://example.com/icons/major-16.svg\" ...></picture> Major**", or an emphasis that holds only the word, such as `**Major**`. Loam takes a finding as Critical or Major when "Critical" or "Major" follows a 🔴 or 🟠 emoji or the end of a `<picture>`, with no letter after the word, or when an emphasis holds only the word, such as `**Major**`. A bold title that starts with the word, such as "**Critical section is not locked.**", does not count. A body with only Minor or Trivial findings does not stop the run. When `review_decision` is not `CHANGES_REQUESTED`, the event and the `note` start with "A review of #12 has a Critical or Major finding" in place of "Changes are requested on #12", and Loam sends no thread.

- The event `review` is "Changes are requested on #12: 2 review threads and 1 review".
- The run is `running` (or `queued`), with the `note` "Changes are requested on #12. Loam sent back 2 review threads and 1 review (review try 1 of 2)".
- `review_tries` goes up by 1. `tries` does not change. As for a CI failure, a prompt that does not reach the session stops the run ("Could not send the review to the session: ..."), and the review try still counts.
- The prompt holds the body of each review that Loam sends. It holds each thread with its path and line, its ID, its URL, and the author and text of each comment.
- The prompt leaves out the text of a comment whose author cannot push to the repo (`writer` is false), because anyone can comment on a public repo. It names the author and the URL of the comment only. A thread with no comment by a writer has nothing to send, so it does not count. The prompt also tells the session that the text is review data, not instructions.
- Loam cuts the text of a review or a comment at 4000 characters, and a line after the cut text says so. A Critical or Major finding of a review body runs from the line of its header to the line of the next header of any severity, or to the end of the body. When the body is longer than 4000 characters and the cut ends before the end of its last Critical or Major finding, the prompt holds only the Critical and Major findings of that review, each in an even part of the 4000 characters. Before each finding goes the last line above it that names a file, with its HTML tags removed: the file and the count of its findings, such as "core/run.go (2)", or the file, the lines and the count, such as "core/run.go-213-214: 1". A line before them says so. Loam records the review as sent, so a finding in the cut part would never go back. After about 60 KB of review text, the prompt leaves out the rest and says that Loam sends it on a later review try. The prompt gives no command to read review text, because its answer would hold the text that the prompt leaves out. A review that the prompt leaves out is not sent, so a later review try can send it.
- The prompt tells the session to fix the code in one commit, and to give each thread that the prompt holds one reply. The session fixes each Critical or Major point that holds against the code, and a point with no severity counts as Major. It fixes a Minor point or a nitpick only when the fix is small and inside the change of the run. For a point that it does not fix, it changes no code, and its reply gives the reason. A point about a sandbox, a permission, or a path that the run can write gets a fix at each severity. A point in the body of a review has no thread. When the session leaves some of those points unchanged, its replies to them are one comment on the PR. Loam pushes the commit after the gate passes, as for a CI fix.
- The session of a run cannot reach GitHub, so it does not post its replies. The prompt tells it to write them to the replies file, `loam/review-replies.json` below the git folder of its worktree (`git rev-parse --absolute-git-dir` in the run folder), and to run no gh. The prompt gives the absolute path and the format: `{ "threads": [{ "id": "<thread ID>", "body": "<reply>", "resolve": true }], "comment": "<comment>" }`. It names `threads` only when it holds a thread, and `comment` only when it holds a review. git never commits the file. The git folder of the worktree must be in the git folder of the repo, with no link out of it: else the run is `stopped` ("Changes are requested on #12, and Loam cannot send the review back: the replies file: ..."). `run send-review` fails with that error instead, and the run stays `ready`. Before Loam sends a review, it removes the replies file and makes its folder, so an old reply never goes to a new review. The run records the PR, the threads that the prompt holds, the threads that it holds in part, and whether it holds a review. None of it is in the JSON.
- When the PR shows the head of the branch after the send-back (Loam pushed the fix, or the session made no commit), Loam posts the replies as the user of gh, before it reads CI. It replies on a thread with `addPullRequestReviewThreadReply`, resolves it with `resolveReviewThread`, and posts the comment with `gh pr comment <number> --repo <owner/name> --body-file -`. Loam takes the file as untrusted. It posts only to the threads that the prompt held, once each, and leaves out a reply to another thread. It resolves a thread only when `resolve` is true and the prompt held all of the thread. When the prompt holds only part of a thread, it tells the session to reply and leave it open, so a later review try sends it again. Loam reads the first 10 comments of a thread, so a thread with 10 comments can have more: the prompt says so, and Loam leaves the thread open after the reply. Loam posts `comment` only when the prompt held a review. An entry with no text posts no reply, and can still resolve its thread. Loam reads at most 1 MB of the file, as a file and not a link, with nothing out of the git folder, and at most 200 thread replies. It cuts a reply or the comment at 8000 characters.
- Each post that ends is a `review` event, and none stops the run. A post that Loam tries again on the next tick has no event until it ends (see below): "Posted 2 review replies and a comment on #12, and resolved 1 thread", with ". Loam left out 1 reply that is not for what it sent" when it left some out. A file that is missing gives "The session wrote no review replies, so Loam posted none on #12". A file that Loam cannot read, or that is not JSON in the format, gives "Loam posted no review replies on #12: the file <path>: <why>". When Loam cannot find the file, the event gives the reason in place of the file. A post that GitHub refuses adds ". 1 post failed, the first with: <why>. The replies stay in <path>" to the event, and is a warning of the tick. When GitHub is out of reach, answers with HTTP 5xx, refuses for its rate limit, or gh is signed out or missing, Loam records what it posted and stops: the tick gives the warning "Loam posts the review replies on #12 on the next tick: <why>", the run waits in `shipping`, and the next tick posts the rest. It does not post again a reply that GitHub took, unless gh timed out or GitHub answered with HTTP 5xx after it took the reply. Loam removes the file when it has posted all of it, also after a retry on a later tick. After a refused post, or with a file that Loam cannot read or that is not in the format, the file stays until the next send-back. A thread that stays open goes back on the next review try.
- Loam sends each review in `change_requests` once: the run records the ID of each review that the prompt holds. GitHub keeps `CHANGES_REQUESTED` until the reviewer reviews again. So when Loam has sent each review and no thread is open, the run is `ready`.
- When the run has used its 2 review tries, the run is `ready`, and `note` adds ". The review tries are used up, and changes are requested on #12" (or "and a review of #12 has a Critical or Major finding").
- When `review_decision` is `CHANGES_REQUESTED` and each review in `change_requests` is of a commit before the head, the `note` of the `ready` run adds ". Changes are requested on #12 only by a review of an older commit, by reviewbot". GitHub keeps the decision until the reviewer reviews again.

**Ship notes and PR template.** Before `gh pr create`, Loam runs `claude -p` in the worktree with the tools Read, Grep, and Glob only, `--output-format json`, a `--json-schema`, `--no-session-persistence`, and the model and effort of the run when it has them. The call stops after 3 minutes, and it needs a folder that Claude Code trusts. The answer has the ship notes: `walkthrough`, `files` (each `{ "path", "role" }`), `risk` (`{ "level", "reasons" }`), and `where_it_stands`. The prompt holds the Where it stands of the plot, the goal, the Done when checks (all passed), the plan of the shape when there is one, the commit messages of the branch, `git diff --stat` of the branch, and the list of changed files. It asks Claude to write plainly and to use no em dashes.

Loam then checks the notes against the diff. It drops a file that the branch did not change, and adds each changed file that Claude left out, with the role "Also changed". A level that is not `low`, `medium`, or `high` is `medium`. Loam adds its own facts to the end of `risk.reasons`, not Claude:

- the changed files that the plan of the shape does not name, such as "1 changed file is not in the plan: go.mod." The fact is there only when the plan names at least one changed file, by its path or its base name. A run with no plan, or a plan that names no changed file, gets no such fact;
- a store migration in the diff: a path with a folder or file whose name holds "migrat", such as `db/migrations/0002.sql` or `app/migrate.go`, or a store schema file: `schema.prisma`, `schema.rb`, `schema.sql`, or `structure.sql`. Another file named `schema` is not one;
- changed dependency files: `go.mod`, `go.sum`, `Package.swift`, `Package.resolved`, `package.json`, and lock files such as `yarn.lock` or `package-lock.json`.

Loam also looks for a PR template in the worktree as GitHub does: `pull_request_template.md` (or `.txt`, any case) in `.github/`, in the root, or in `docs/`, else the first file, by name, of a `PULL_REQUEST_TEMPLATE/` folder in one of them. With a template, the same call also asks for `{ "title", "body" }`, and the prompt holds the template. It asks Claude to fill each section, to follow the comments of the template, and to tick a checkbox only when a check proves it. The PR title is the title that Claude gives, else the title of the run. The body is the body that Claude gives, a blank line, and the footer: the issue line (`Closes #57` or `Linear: ENG-523`), the line about the other runs of a group, and "Loam opened this PR for a run whose checks passed." With no template, the PR has the title and the body described in step 4.

When `claude -p` fails, times out, or gives no walkthrough, the run has no `notes`, and a `ship` event says why: "Loam wrote no ship notes: <why>", or with a template "Loam used no PR template and wrote no ship notes: <why>". A template answer with no body keeps the body of step 4, with the event "Loam used no PR template: claude -p gave an empty body". The PR text is not part of the JSON contract. When Claude wrote the notes, Loam saves the PR text and the notes on the run before it asks gh to open the PR. When gh cannot open it, a later tick opens it with the saved text, and calls no `claude -p`, while the branch head is the same. Text that Loam wrote because Claude could not is not saved, so the next tick asks Claude again. A fix that Loam pushes after a CI failure or a send-back keeps the notes of the first push. Only the facts of the code review change: the review of each push replaces those of the review before.

**Code review.** Before Loam pushes a head of a run, or opens a PR for it, Loam runs a code review of the diff of the branch, from where it left the base of its worktree to that head. The review runs once for each head, not after each turn. It is a separate `claude -p` in the worktree, not a prompt in the run session, with the tools Read, Grep, and Glob only, `--output-format json`, a `--json-schema`, and `--no-session-persistence`. The model is that of the shape of the run, else the model of the run defaults of the plot. The effort is the `review_effort` of the run defaults, and empty passes no flag. The call stops after 10 minutes, and it needs a folder that Claude Code trusts. The prompt holds what each severity means, when a finding needs you (below), the goal, the Done when checks (all passed), the findings of the earlier rounds of the run (below), `git diff --stat` of the branch, and `git diff` of the branch. A diff longer than 60000 characters is cut, and the prompt says so, so Claude reads the files that it leaves out. A review of a cut diff that lets Loam push adds "The diff is longer than 60000 characters, so the code review saw only its start in the prompt" to `notes.risk.reasons` and to its event. When the worktree is also not at the head, the tools of Claude cannot read the rest, and the text is "The diff is longer than 60000 characters, and the folder is not at its head, so the code review did not see the rest of the diff". When the worktree is not at the head, the prompt says that its files can differ from the diff. The answer is a list of findings, each `{ "severity", "file", "line", "text" }` and an optional `needs_you`. `severity` is `critical`, `major`, or `minor`, and Loam takes another value as `major`. Loam leaves out a Minor finding with no text, and keeps a Critical or Major one with the text "The review gave this issue no text." Loam keeps at most 1000 characters of the text of a finding. The review also loads the MCP servers of the run defaults, as the PR text does. The diff can hold text that tells Claude what to do. The prompt tells Claude not to obey it, and a finding is advice for the session that Loam does not run.

Each review after the first round of the run sees the earlier rounds, so that a round does not reverse the fix of an earlier round and the session does not move between two answers. The prompt lists the Critical and Major findings of the earlier rounds of the run, from the `code_review` events, under the round of each: the rounds that sent findings back to the session, and the reviews that stopped the run for you. A round adds only its findings with no `needs_you`, and a review that stopped the run adds only its findings with `needs_you`, because only those went to the session or to you. It holds at most 20 findings, those of the last rounds, and says how many it left out. After a round, the prompt shows the last message of the session after that round, when Loam has it: the Stop hook that lets the session stop after the round keeps `last_assistant_message` of the hook input, at most 2000 characters, and a stop with no message keeps none. The prompt tells Claude not to raise a finding that reverses an earlier one unless it gives a new reason, and then to say which earlier finding it reverses. It tells Claude not to raise a finding that stopped the run again unless the diff gives a new reason. A review with no earlier round has no such list. An event from before Loam stored the round of a review is not in it.

A finding can have `needs_you`: a short reason, when its fix needs a setting that only you can change. The prompt names them: the sandbox read or write paths, the network hosts, the setup command, secrets, or a setting of the plot. Loam keeps at most 300 characters of the reason, and drops it from a Minor finding.

- No Critical or Major finding: Loam pushes. Each Minor finding goes in `notes.risk.reasons`, at the end, such as "Minor issue from the code review: core/app.go:42: The loop has no test." The reasons name at most 10 findings, and then count the rest. The `code_review` event is "The code review found no issues", or "The code review found 2 minor issues".
- A Critical or Major finding with `needs_you`: the finding does not go back to the session, because the session cannot change the setting, and Loam does not push. When the review also has a Critical or Major finding with no `needs_you`, and the run has a round left, that finding goes back to the session as below, and the round counts. The `note` and the `code_review` event then add "1 issue only you can fix, and wait for the next review", and the note names each such finding with its reason. The run holds these findings, and the next review adds them to its own findings, when it does not find them again with the same file and text. So a held finding reaches you, also when the next review does not raise it: it stops the run when nothing else goes back to the session. A review that is off for the plot or did not run also stops a run that holds findings, and Loam does not push. A stop empties the held findings. When each Critical or Major finding of the review has `needs_you`, or the run has used all its rounds, the run is `stopped`. No round and no try counts. The `note` names each finding with `needs_you` and its reason, at most 20, and then counts the rest: "The code review found 1 issue that only you can fix, so the run stops:", a line "- Major: core/gate.go:42: The gate fails when the sandbox cannot read the cache. Needs you: The sandbox needs a read path for the cache." for each, then "The code review also found:" and a line for each other Critical or Major finding, when the review has one, and "Change the setting, then run loam run send-back to start the run again." The `code_review` event is the first line of the note without the colon.
- A Critical or Major finding with no `needs_you` while the run has a round left: Loam does not push, and the round counts. The run is `running` (or `queued`, with the prompt, when no slot is free), and Loam sends the session the Critical and Major findings as it sends a CI failure: at most 20, and then a count of the rest. No try counts: the rounds are separate from the tries. The next gate that passes reviews the new head. The `code_review` event and the `note` are "The code review found 1 major issue and 1 minor issue (round 1 of 5)". The prompt of round 5 tells the session that it is the last round.
- A run has 5 rounds in all. The count is for the whole run: a review that lets Loam push does not start it again, and neither does a CI failure, a PR review, or a send-back that sends the run back to its session. After the 5th round, Loam still reviews each new head once, and pushes. The Critical and Major findings do not go back to the session. They go in `notes.risk.reasons` after "The code review used all 5 rounds of the run, so these findings wait for you:", one reason for each, such as "Major issue from the code review: core/app.go:42: The loop reads past the end", at most 20, and then a count of the rest. The Minor findings follow, as above. These findings set `notes.risk.level` to `high`. A run with no `notes`, because Claude wrote none, gets notes that hold only this risk, with the level `high`, when its PR is open or when Loam opens it. Loam adds no walkthrough comment to Linear for such notes. The `code_review` event is "The code review found 1 major issue after all 5 rounds of the run, so Loam pushes with them in the ship notes". A head that the review already let Loam push starts no new round.
- The review is off for the plot (see the run defaults): Loam pushes with no review. The `code_review` event is "The code review is off for the plot, so Loam pushes with no review".
- The review did not run: `claude -p` failed, timed out, or gave no answer that Loam can read, or the folder is not trusted. Loam pushes, and adds "The code review did not run: <why>" to `notes.risk.reasons`. The `code_review` event is "The code review did not run, so Loam pushes with no review: <why>". A tick that ends during the review, such as on Ctrl-C, records nothing, and a later tick reviews the head.

Each CI result is a `ci` event.

A tick also watches the PR of each run that is `ready` and has a `pr`. A merge on GitHub lands the run, as in step 2, and a close stops it. A run whose worktree is gone reads its PR by number, as in step 1. A run that cannot reach GitHub waits with no warning.

A Ready run with an open PR can also go back to `shipping`, so a later tick reads CI on the new head:

- The branch of the worktree has commits after the PR head. The tick runs the code review of the branch head first. A Critical or Major finding sends the run back to its session while the run has a round left, as above. After the last round of the run, a Critical or Major finding does not send the run back: Loam pushes with the findings in the ship notes (see Code review). A finding with `needs_you` waits for the next review or stops the run, as above. Else the tick pushes the commits at once, with the `note` "The branch has commits after the head of #12. Loam pushes them, and CI runs again" and the `ship` event "Pushed the new commits to #12". The tick reads the branch, not `HEAD`, so a commit on another branch changes nothing. A failed push stops the run, as in step 4.
- The checks of the PR run, wait, or failed on the head of the branch, such as after a push by hand: `note` and `ship` event "The checks of #12 run or failed after it was ready. Loam reads CI again".
- The review of the PR requests changes, or a review in `comment_reviews` has a Critical or Major finding, Loam has something to send (see Reviews), and the run has review tries left: `note` and `review` event "Changes are requested on #12 after it was ready. Loam sends the review back" (or "A review of #12 has a Critical or Major finding after it was ready. ..."). A later tick sends the review when CI passes.

A Ready run whose PR head is the head of the branch and is `CONFLICTING`, such as after another PR landed, goes back to its session at once to merge its base, as in step 5. The conflict comes before the checks and the review above, and while `mergeable` is `UNKNOWN` the run changes nothing.

None of these applies while a land waits for GitHub (an auto merge, or a PR in a merge queue), because GitHub merges the PR as it is. A PR head that the branch does not have, such as a push from another machine, changes nothing, also when its checks run or fail, because Loam cannot push it. The Done when checks do not run again, and the run keeps the ship notes of its first push.

A tick also stops a run that is `running` when its session ended a turn that Loam has no record of. That happens when the Stop hook cannot record the end of the turn: for example, the store fails with "database or disk is full", or the hook crashes or times out. The run must have a session, and no change and no event for 10 minutes. Then the tick reads the background sessions with `claude agents --json --all`, one call for all the runs. The session is idle when its `state` is `done` or `stopped`, or when the list does not have it. claude gives a `sessionId` only when the session has one, so a list with a session that has no `sessionId` makes a session that the list does not name not idle. `working`, `blocked`, and any other state are not idle, and the run waits. An idle run is `stopped`, and counts no try. Its `note` is "The session ended a turn, but Loam has no record of its checks. Run loam run send-back to start it again". The tick does not run the gate. A check can run for 10 minutes with no event, so the Stop hook holds a lock on `<home>/gates/<run-id>.lock` while it runs the gate, and the tick leaves a run whose lock is held. The lock ends with the hook process, so a hook that crashes or times out does not keep it. `claude agents` can show the session as done before the Stop hook takes the lock, so a tick can stop the run first. For 2 minutes after the stop, a Stop or StopFailure hook moves a run that is `stopped` with that `note` as it moves a `running` run: the gate runs, and its result replaces the note. Later, the run is not running, as for any `stopped` run: when you type in its session, each turn ends with no gate. When claude is missing, or `claude agents` fails or gives a list that Loam cannot read, the tick gives a warning, and the run waits.

#### Land

| Command | Output |
| :- | :- |
| `loam run diff <run>` | `{ "base": "<commit>", "head": "<commit>", "files": [{ "path": "README.md", "status": "modified", "added": 3, "deleted": 1, "hunks": [{ "header": "@@ -1 +1,3 @@", "old_start": 1, "new_start": 1, "lines": [{ "kind": "del", "old": 1, "text": "hello" }, { "kind": "add", "new": 1, "text": "# Loam" }] }] }] }` |
| `loam run send-back <run> --note <text>...` | `{ "run": { ... }, "rule_offer": { "note": "...", "earlier": "...", "earlier_run_id": "...", "earlier_title": "..." } }` |
| `loam run send-review <run> [--dry-run]` | `{ "run": { ... }, "pr": { ... }, "threads": 1, "reviews": 0 }` |
| `loam run land <run> [--head <commit>] [--keep-worktree] [--no-linear-done] [--where-it-stands] [--open-pane <folder>]... [--dry-run]` | `{ "run": { ... }, "land": { ... }, "warnings": [] }` |

- `run diff` is the work that the run committed: from `base`, the commit where its branch left the base of its worktree, to `head`. `head` is the head of the worktree. For a `ready` run with a `pr`, it is the head that Loam pushed (`origin/<branch>`), so the diff is the work that `run land` merges. When the worktree has no `origin/<branch>`, `run diff` of that run fails. `status` is `added`, `modified`, `deleted`, or `renamed`, with `old_path` for a rename. A binary file has `binary` and no hunks. A file keeps at most 3000 lines and then has `truncated`; `added` and `deleted` count every line. A line has `old`, `new`, or both: the numbers of the line before and after the change.
- `run send-back` takes a run that is `ready`, `shipping`, or `stopped`, and at least one note. A `shipping` run goes back as a `ready` run does, for example when its PR conflicts with main. A tick that ships the run at that moment writes nothing to it: each write of the tick checks that the run still has the state and the count of turns that the tick found. The count catches a run that went round in one tick: it went back, its session ended a turn, and the gate made it `shipping` again. When a tick moves the run first, for example to resume it with a CI failure, the send-back writes nothing and exits with code 2: "the run moved from shipping to running while Loam sent your notes, so they did not go back. Look at the run, then send them again". A note is `<file>:<line>: <text>` for a line, or text alone. Loam stops the session and resumes it with the notes as its prompt, as for a CI failure, and the run is `running` ("Sent back with 2 notes", event `review`). A note uses no try. A run with no tries left gets one more (`max_tries` goes up by 1, to at most 8). The next gate that passes ships the change to the same PR. Each note is an event `note`: `<file> line <n>: <text>`, or the text alone.
- `run send-review` takes a run that is `ready` and has a PR. It reads the PR from GitHub and sends its review back to the session, as the tick does for a review that requests changes (see Reviews), with these differences. The `review_decision` does not matter: each thread that is not resolved and has a comment by a writer goes back, and each review in `change_requests`, or in `comment_reviews` with a Critical or Major finding, that Loam has not sent. The prompt starts with "I ask you to address the review of #12." and has the same filter for the text of readers. You choose this send, so `review_tries` does not change, and the review tries only limit what Loam sends alone. The run is `running` ("You sent back the review of #12. Loam sent back 2 review threads", event `review`), and the next gate that passes ships the fix to the same PR. Loam records the ID of each review it sends, so it does not send that review again. `pr` is the PR as GitHub has it now, in the form of `worktree list`, with `review_decision`, `change_requests`, `review_threads`, and `comment_reviews`. `threads` counts the threads that Loam sends, and `reviews` counts the reviews. `--dry-run` changes nothing: the `run` is as it was, and `threads` and `reviews` say what Loam would send, which can be 0. The desk uses it to show the review of a `ready` run. It exits with code 2 when the run is not `ready`, has no PR, or when #12 is not open or has nothing to send, and with code 17 when gh is missing or signed out.
- `rule_offer` is there when a note is like a note on another run of the plot: they share at least 2 words, and at least half of all their words, when Loam leaves out short and common words. A note like the `note` of a rule of the plot gets no offer. `note` and `earlier` are the texts of the two notes, and `earlier_run_id` is the other run. The app offers to make the note a rule with `loam rule add`.
- `run land` takes a run that is `ready` and has a `pr`. Loam checks the land first with a dry run. When the land can go on, Loam stops the session, because the land removes the worktree. A land that refuses keeps the session. Loam then lands the worktree as `loam worktree land` does, with the default merge method: `land` is the `worktree land` result. A merge makes the run `landed` ("Merged #25 with squash", event `land`), and its Linear issue moves to the first completed state (event `linear`). A run of a group moves it only after the last run of the group (see Linear). With a merge queue, the run stays `ready` ("#25 is in the merge queue of main"), and a tick lands it when GitHub merges. `--dry-run` changes nothing, and `land` is the plan.
- A run whose worktree is gone reads its PR by number (see Ship, step 1) and calls no land. A merged PR makes the run `landed` ("#25 was merged on GitHub") and a closed PR makes it `stopped`. In both cases `land` is `null`. With `--dry-run`, `land` is `null` and `warnings` says what a land records. An open PR exits 2: Loam cannot merge a PR with no worktree.
- `loam worktree land` also lands each run that works in the worktree and has not ended (`shipping` or `ready`), when the land merged the PR, so a land from the sidebar ends the run at once. The note is the one of `run land`. A run with a `pr` other than the merged one stays as it is. `landed_runs` holds each run that the land landed, and `run_warnings` says what went wrong on the way, such as an update to Linear that failed. Both are always there, and empty when the land landed no run. The text output adds the line "Landed the run <title>." for each run, and prints each warning on stderr. In the `land` of `run land`, both are empty: `run land` has its own `run` and `warnings`.
- A run in another state, or with no PR, exits 2. A check that blocks the merge exits 16, and gh missing or signed out exits 17, as for `worktree land`.
- `--keep-worktree` keeps the worktree after the merge.
- `--no-linear-done` leaves the Linear issue where it is: this land does not move it to Done, and the `linear` event is "This land leaves ENG-523 where it is". It holds only for a land that merges now. When GitHub merges later, a run with a Linear issue gets a warning that the tick that lands the run follows the `done` switch.
- `--where-it-stands` sets the Where it stands of the plot to `notes.where_it_stands` when the run lands, through the same store path and change log as `loam set <plot> where-it-stands` and the MCP tool `set_where_it_stands`. The actor is that of the command. A run with no `notes`, or with an empty `where_it_stands`, exits 2 before Loam merges anything. A land that does not land the run now, such as one that waits for a merge queue, sets nothing, and a warning says so. A failed write is a warning, because the merge has happened.

#### Shape

| Command | Output |
| :- | :- |
| `loam run shape <plot> --title <text> [--repo <repo> \| --split] [--base <branch>] [--link <link> \| --ticket <file>] [--max-tries <n>] [--model <model>] [--effort <level>] [--fixes <run>]` | `{ "run": { ..., "state": "shaping", "shape": { "assumptions": [{ "text": "...", "answer": "" }], "follow_ups": [{ "title": "...", "body": "...", "target": { "kind": "github", "label": "owner/name", "url": "https://github.com/owner/name" }, "kept": true }], "plan": ["..."], "size": "...", "drafted_at": "...", "repo": "repoaaaaag", "base": "", "link": "", "model": "", "effort": "" } }, "runs": [{ ... }] }` |
| `loam run redraft <run> [--change <text>]` | `{ "run": { ... }, "runs": [{ ... }] }` |
| `loam run approve <run> [--goal <text>] [--check <name>=<command>]... [--no-checks] [--answer <n>=<text>]... [--drop-follow-up <n>]... [--approve-setup]` | `{ "run": { ... }, "worktree": { ... } }`, as for `run start` |

- `run shape` records a run that is `shaping`, with the repo as its `folder` and no worktree, then has Claude draft it: `claude -p` in the repo, with the tools Read, Grep, and Glob only, `--output-format stream-json --verbose`, a `--json-schema`, and `--no-session-persistence`. The prompt holds the title and the text of the issue: the ticket file, `gh issue view`, or the Linear issue. The draft sets `goal` and `done_when`, and `shape` holds the rest (event `shape`). The command can take minutes. While Claude drafts, each step that it takes is an event `draft`, such as `Read window/frame.go`, `Searched for SaveFrame`, or the first line of its text, up to 100 steps for one draft. The app reads them to show the draft as it happens.
- While Claude drafts, the `note` is "Claude is drafting the run". A run that Claude has not drafted yet has no `drafted_at`. A first draft that fails keeps the run `shaping` with no `drafted_at`, and the `note` says why ("Claude could not draft the run: ..."). The command exits 0.
- `run redraft` drafts a `shaping` run again. `--change` is what you want changed: Claude gets its last draft and the change.
- `run` is the run that the command recorded or drafted. `runs` is every run that it made, with `run` first. It is always there, and it has one run unless a split made more.

`--split` is for an issue that needs changes in more than one repo of the plot. Claude reads every repo and drafts one run for each repo that the issue needs changes in.

- `--split` with `--repo` exits 2. In a plot with one repo, `--split` is a normal shape.
- `claude -p` runs in the main repo, with `--add-dir <path>` for each other repo, so that Read, Grep, and Glob can read them. Claude Code must trust every repo. An untrusted repo is a failed draft, with the folder in `note`.
- The schema of a split draft is `{ "runs": [{ "repo": "<repo id>", "goal": "...", "checks": [...], "assumptions": [...], "follow_ups": [...], "plan": [...], "size": "..." }] }`, with 1 or more runs and each repo at most once. The prompt lists each repo with its ID, name, and path. It tells Claude that each run works alone in a worktree of its repo, that its checks run there, and that the runs may land in any order. So each run must be correct alone, or say in an assumption what it needs from another run.
- The steps of the draft are `draft` events of the first run.
- The run that the shape recorded becomes the run of the first repo of the draft: its `folder` and `shape.repo` are that repo. Each other repo gets a new `shaping` run that Claude has drafted, with the same title, `source`, `max_tries`, `link`, model, and effort. `shape.base` is kept for the main repo and is empty for another repo. Each run gets a `shape` event.
- With 2 or more runs, every run of the split gets the same `group_id`: the ID of the first run. A draft with one run has no group.
- A draft with a repo that the plot does not have, or with a repo twice, fails as a whole. The first run keeps the reason in `note`, and Loam makes no other run.
- While a split has no draft, `shape.split` is `true`, so `run redraft` splits again. After the split, `shape.split` is left out. A redraft of a run of a group drafts that run alone, for its own repo.
- You approve each run of a group with `run approve`.
- `follow_ups` are the work that the draft leaves out on purpose, such as "A picker in the app". The schema of a draft has them next to `assumptions`: each is `{ "title", "body", "target" }`. Claude leaves `target` empty, unless the run has no issue and the plot has Linear links (below). In the run, each follow-up is `{ "title", "body", "target": { "kind", "label", "url" }, "kept", "filed", "error" }`. `kept` is `true` until you drop it. `filed` (`{ "key", "url" }`) and `error` are left out until approve. Loam picks the target:
  - A run from a GitHub issue files in the repo of that issue (`kind` `github`, `label` `owner/name`).
  - A run from a Linear issue files in the Linear project of that issue (`kind` `linear`). `url` is left out.
  - A run with no GitHub or Linear issue, such as a map ticket, a recurring run, or a plain goal: the prompt lists the Linear project and team links of the plot with their labels, and Claude puts the URL of the best fit in `target`. The run records that link (`kind` `linear`, `label` the label of the link, `url` its URL). A `target` that is none of the links gives the first link. A plot with no such link files a GitHub issue in the origin repo of the run. A repo with no GitHub origin gives a target with no `url`, and approve cannot file it.
- `run approve` takes a `shaping` run that has a draft. Loam makes the worktree, as `run start` does with the `repo`, `base`, and `link` of the shape, and starts the session. `--goal` and `--check` replace the draft's, and `--no-checks` removes the draft's checks (it exits 2 with `--check`). `--answer` sets the `answer` of an assumption, by number from 1. The session prompt holds the assumptions, with your answer in place of an assumption that you changed, and the plan. A run in another state, a run with no draft, or an answer to no assumption exits 2. Approve also files each follow-up that you did not drop with `--drop-follow-up <n>` (number from 1, repeatable; a number that is no follow-up exits 2). A Linear follow-up becomes an issue in the project (or the team) of its target, and when the run has a Linear issue, a related link joins them. A GitHub follow-up becomes an issue (`gh issue create`) whose body names the GitHub issue of the run, or the run. Each result is a `followup` event, and the keys and URLs are in `shape.follow_ups[].filed`. A filing that fails does not stop the run: the run starts, `shape.follow_ups[].error` says why, and the command prints a warning. The PR body of the run has a Follow-ups section that lists each filed issue. A Linear issue shows its key only, with no title and no URL, because the repo can be public. A GitHub issue shows its number and its title. A redraft makes the follow-ups again, all kept.
- `run cancel` on a `shaping` run cancels it, with no `claude stop`.
- The `shape` of a run that a recurring run shaped has a `brief`: the prompt of the recurring run and what its precheck printed. Claude drafts from it, as from the text of an issue.

#### Model, effort, and run defaults

`run start`, `run shape`, and `recurring add` take `--model <model>` and `--effort <level>`. The level is `low`, `medium`, `high`, `xhigh`, or `max`. Loam passes them to Claude Code as `--model` and `--effort`: to the session of the run, and for `run shape` also to `claude -p`, which drafts the run. `run approve` starts the session with the model and effort of the shape. An empty value passes no flag, so Claude Code uses its own setting. A level that is not in the list exits 2, and the message lists the levels.

A plot can have run defaults: a model, an effort, MCP servers, and the code review before each push. A run, a Shape run, and a recurring run that fires use the default of the plot for the model or the effort that it leaves empty. A flag or a field that is set wins. Loam fills the model and the effort when it starts or shapes the run, so a change of them does not change a run that exists. The MCP servers are not stored on the run: Loam reads `mcp_servers` each time it drafts a run, writes the PR text, or reviews the code, so a change of the list holds for the next draft, PR text, or review of a run that exists. `review` turns the code review on or off (see Ship), and `review_effort` is its effort level. Loam reads them at each push, so a change holds for the next push of a run that exists. Run defaults are not in the change log. Deleting a plot deletes its run defaults.

The MCP servers are for `claude -p`, which drafts a Shape run, writes the PR text of a run, and reviews its code. A draft runs in the repo folder of the run, before Loam makes a worktree. The PR text and the code review run in the worktree of the run. So a selected server tool that writes a relative path writes in that folder. Loam starts it with `--strict-mcp-config` and an `--mcp-config` that holds only the servers that `mcp_servers` names, so no claude.ai connector and no other server loads. An empty list loads no MCP server. Loam copies each definition from the user scope of the Claude Code config: `mcpServers` in `.claude.json` (in `CLAUDE_CONFIG_DIR`, else the home folder), which `claude mcp add --scope user` writes. Loam does not read `.mcp.json`: it is a file of the repo, which a PR or the session of a run can change, and Claude Code asks you to approve a project server, which `--mcp-config` skips. Loam does not read a local scope either: a local scope is keyed by folder, and the PR text runs in a worktree, not in the folder where you added the server. The user scope is the same for each folder. Loam does not copy a server with a `headersHelper`, and the name stops the draft as a missing name does. Claude Code runs the helper of a user-scope server in the config folder. It runs the helper of an `--mcp-config` server in the session folder: the repo folder for a draft, and the worktree for the PR text and the code review. With no servers, the config goes on the command line. With servers, it goes in a temporary file that only you can read, because a definition can hold a token, and Loam removes the file when `claude -p` ends. A claude.ai connector is not in a local file, so no name selects one. The tools of a selected server run as your Claude Code permissions allow: `--tools Read,Grep,Glob` limits only the built-in tools, so a server tool that your settings allow can write. A name that Loam cannot find stops the draft, and the note of the run names the server. With no PR text, the run gets a `ship` event that says why. A review that cannot load them does not run, and Loam pushes with a `code_review` event that says why (see Ship). The session of a run loads its MCP servers as Claude Code does.

```json
{ "plot_id": "k3v9q2mxa7", "model": "opus", "effort": "high", "mcp_servers": ["loam"], "review": true, "review_effort": "" }
```

| Command | Output |
| :- | :- |
| `loam run defaults <plot> [--model <model>] [--effort <level>] [--mcp <names>] [--review on\|off] [--review-effort <level>]` | `{ "defaults": {...} }` |

- With no flag, the command prints the defaults. A plot that has none prints empty strings for `model`, `effort`, and `review_effort`, `[]` for `mcp_servers`, and `true` for `review`.
- A flag sets that field and leaves the others. An empty value clears the field.
- `--mcp` takes a comma-separated list of server names. Loam trims each name and leaves out empty names and repeats. The command prints the defaults after the change.
- An `--effort` or a `--review-effort` that is not a level exits 2. A `--review` that is not `on` or `off` exits 2.

`loam run mcp-servers` lists the servers that `--mcp` can select. It takes no plot, because the user scope is the same for each plot.

```json
{ "servers": [{ "name": "linear-server", "scope": "user" }, { "name": "loam", "scope": "user" }] }
```

| Command | Output |
| :- | :- |
| `loam run mcp-servers` | `{ "servers": [{ "name": "...", "scope": "user" }] }` |

- The list holds the servers in `mcpServers` of the user scope of `.claude.json`, sorted by name. `scope` is always `user` for now, so a later scope needs no change of the shape.
- The list leaves out a server with a `headersHelper`, because `--mcp` rejects it, and a server whose name has a comma or edge spaces, because `--mcp` cannot keep the name. It has no `.mcp.json` server, no local-scope server, and no claude.ai connector, for the reasons above.
- A missing config file gives `[]`.

#### Limits, the queue, and usage

The run limits hold for every run of every plot. There is one set, and it is not in the change log.

```json
{ "at_a_time": 3, "max_turns": 40, "hold_at": 80 }
```

- `at_a_time` is how many runs can hold a slot at once: 1 to 20. The default is 3. A run in `starting`, `running`, or `start_unknown` holds a slot. A run in `shipping` or `ready` does not: its session waits for CI or for you.
- `max_turns` is how many turns a run can take. The default is 40. 0 means no limit.
- `hold_at` is a percent of the 7-day usage of Claude Code: 0 to 100. The default is 80. 0 turns the hold off.

The usage is the last usage that Claude Code reported to Loam. It is not in the change log. A write of it rewrites `loam.changed`, so the app must not run `usage --refresh` each time the change feed wakes it.

```json
{
  "five_hour": { "utilization": 0.18, "resets_at": "2026-10-28T14:00:00Z" },
  "seven_day": { "utilization": 0.41, "resets_at": "2026-11-01T09:00:00Z" },
  "read_at": "2026-10-28T10:12:00Z"
}
```

- `utilization` is the share of the window that is used, from 0 to 1. `resets_at` is when the window starts again.
- A window is `null` until Claude Code reports it. `read_at` is `null` before the first report. All three keys are always there.

| Command | Output |
| :- | :- |
| `loam run limits [--at-a-time <n>] [--max-turns <n>] [--hold-at <percent>]` | `{ "limits": {...} }` |
| `loam usage [--refresh]` | `{ "usage": {...} }` |

- With no flag, `run limits` prints the limits. A flag sets that limit and leaves the others. A value out of range exits 2.
- Each path that starts or resumes the session of a run checks for a slot first: `run start`, `run approve`, a recurring chore, `run send-back`, and the CI failure that `run tick` sends back. The run goes to `queued` instead when:
  1. `hold_at` is not 0, and the known 7-day `utilization` is at or over `hold_at` percent. `note` is such as "Held: the week's usage is at 82%, over the 80% limit". A 7-day window whose `resets_at` has passed is not known.
  2. Else the other runs that hold a slot are `at_a_time` or more. `note` is such as "Waits for a slot: 3 of 3 runs are running".
- A queued run keeps how it starts: a new session with the model and effort of the run, or a resume of its own session with your notes or the CI failure. A send-back that waits keeps its `review` and `note` events. A CI failure that waits counts its try at once.
- `run tick`, and the tick that `loam tick` runs, start the queued runs, oldest first, while a slot is free and the usage is under the hold. A new session goes to `starting`, then `running`, as for `run start`. A resume goes to `running`. A run that still waits gets a new `note` only when the reason changed, so a tick that starts nothing writes nothing.
- When the hold is on, a slot is free, a run waits, and the usage is more than 30 minutes old or was never read, the tick runs the probe first (see below). A probe that fails is a warning, and the tick uses the usage that it has. Loam tries at most one probe in 30 minutes, whether it works or not, so a probe that fails does not run again on each tick. Separate `loam` processes share that time.
- `run start`, `run approve`, and `run send-back` run the probe first too, when the hold is on, a slot is free, and the usage is more than 30 minutes old or was never read, under the same limit of one probe in 30 minutes. So an action of yours costs at most one probe. A probe that fails leaves the usage that Loam has, and the run is held or not by it, as before.
- The app counts the runs that are running and the runs that wait from `loam run list`: the states `starting`, `running`, and `start_unknown` hold a slot, and `queued` waits.
- At each Stop of a `running` run, when the checks fail and `max_turns` is not 0 and the turns since Loam last resumed the session reach `max_turns`, the run is `stopped` with the note "Stopped after 40 turns, the limit for each run". Loam resumes the session with your notes (`run send-back`) and with a CI failure, also from the queue, and each resume starts the count again. `turns` stays the total. No try counts. A Stop whose checks pass ships as always.
- Loam records the usage from each `claude -p` call that it makes with `--output-format stream-json`: a Shape draft, and the probe. Claude Code reports it as a `rate_limit_event` line, whose `rate_limit_info.unifiedWindows` holds `five_hour` and `seven_day`, each with `utilization` and `resetsAt` in Unix seconds. A window that a report does not have keeps its last value.
- `usage --refresh` runs the probe: `claude -p "Reply with ok" --model haiku --output-format stream-json --verbose --no-session-persistence --tools ""` in a new temp folder, for at most 60 seconds. It records the usage and prints it. A probe that fails, or that reports no usage, exits 1.

#### Metrics

`loam run metrics` shows where the time of the runs goes, from approve to landed (TAS-176). It reads the run events in the store, so it covers every run since Loam had runs. A run that you delete with its plot leaves the metrics. All times are wall time.

| Command | Output |
| :- | :- |
| `loam run metrics [--plot <plot>] [--since <time>]` | `{ "current": {...}, "previous": {...} }` |

`current` is the window from `--since` up to now, or the last 30 days. `previous` is the window of the same length that ends where `current` starts. `--since` takes an RFC 3339 time. A time that does not parse, or that is not before now, gives exit code 2. With `--plot`, the metrics hold the runs of that plot only. Each window is:

```json
{
  "from": "2026-09-29T09:00:00Z", "to": "2026-10-29T09:00:00Z",
  "landed": 5, "first_pass": 4, "fixed": 0,
  "lead_time": { "count": 5, "median_seconds": 7843, "p90_seconds": 8768 },
  "stations": { "approve": {...}, "queue": {...}, "build": {...}, "ship": {...}, "merge": {...}, "stopped": {...} },
  "recovery": { "gate": {...}, "ci": {...} },
  "rework": { "gate_tries": 1, "ci_tries": 0, "review_tries": 0, "code_review_rounds": 0, "redrafts": 2, "turns": 10 },
  "not_landed": { "stopped": 0, "limited": 0, "cancelled": 0, "start_unknown": 0 },
  "slowest": [{ "run_id": "runraaaaab", "plot_id": "k3v9q2mxa7", "title": "Fix the login form", "lead_seconds": 8768 }]
}
```

- A landed run counts in the window that it landed in. `landed`, `first_pass`, `fixed`, `lead_time`, `stations`, `rework`, and `slowest` hold the landed runs of the window.
- A spread has `count`, and the median and the 90th percentile in seconds, by the nearest rank: the time at rank ceil(q × count) of the sorted times. Both are 0 when `count` is 0.
- `lead_time` runs from approve, when the run leaves `shaping`, to `landed`. A run with no draft starts when Loam records it.
- `stations` add each visit to a state, so a run that goes from `ready` back to `shipping` adds both visits. `approve` is `shaping`, `queue` is `queued`, `build` is `starting` and `running`, `ship` is `shipping`, `merge` is `ready`, and `stopped` is `stopped`, `limited`, and `start_unknown`. The stations other than `approve` add up to the lead time of a run. Each spread holds every landed run, with 0 for a station that the run did not pass. `approve` holds only the runs that had a draft.
- `first_pass` counts the landed runs that used no try and no review try.
- `fixed` counts the landed runs that a later run fixes (`--fixes`), unless you cancelled the fix. It is the change failure count, and it can grow after the window ends.
- `recovery` times each failure to the next pass. `gate` is from a failed gate until the run is `shipping`, `ready`, or `landed`. `ci` is from a failed CI until the run is `ready` or `landed`. A gate that fails while the run fixes a CI failure is part of that CI failure. A failure counts in the window that it started in, for any run. A failure that never passed does not count, and nor does a failure whose run stopped or was cancelled before it passed, for any reason: the `stopped` station holds that wait.
- `rework` adds up the loops of the landed runs. A try of the gate and a try of CI each count once. `code_review_rounds` counts the code reviews before a push that found a Critical or Major issue. `redrafts` counts the drafts after the first one, with the drafts that failed.
- `slowest` holds the landed runs of the window with the longest lead time, longest first, at most 5. Runs with the same lead time go in the order of their IDs. It is `[]` when no run landed.
- `not_landed` counts the runs whose last state is in the window and is `stopped`, `limited`, `cancelled`, or `start_unknown`.

#### Rules

A rule is a check that every run of a plot must pass, such as "Views use the colour tokens" (ticket 209). Loam keeps the rules in the store, outside the worktree, so a run cannot change them. Rules are not in the change log, as runs are not.

```json
{ "id": "ruleaaaaab", "plot_id": "k3v9q2mxa7", "name": "Short README", "command": "test $(wc -l < README.md) -lt 40", "note": "Keep the README short.", "created_at": "2026-10-01T09:00:00Z" }
```

| Command | Output |
| :- | :- |
| `loam rule add <plot> --name <name> --command <command> [--note <text>]` | `{ "rule": {...} }` |
| `loam rule list [<plot>]` | `{ "rules": [...] }`, oldest first |
| `loam rule rm <rule>` | `{ "rule": {...} }`, the one that it removed |

- The gate runs the rules of the plot after the checks of the run, each as the check `Rule: <name>`, with `sh -c` in the folder of the run and in the sandbox of the run. A rule that fails blocks the stop as a check does. The session prompt lists the rules with the checks.
- `note` is the note that the rule came from. A note like it gets no `rule_offer`.
- A name or a command that is empty exits 2.

#### Recurring

A recurring run starts on a timetable, such as weekdays at 06:30, when its precheck finds work (ticket 208). `loam tick` starts it when it is due. Recurring runs are not in the change log, as runs are not.

```json
{
  "id": "recuaaaaab", "plot_id": "k3v9q2mxa7", "title": "Bump Go dependencies", "prompt": "Bump the Go modules that have updates.",
  "kind": "chore", "days": ["mon", "tue", "wed", "thu", "fri"], "at": "02:00",
  "precheck": "go list -m -u all | grep -q '\\['", "if_asleep": "once", "repo": "",
  "done_when": [{ "name": "Go tests", "command": "go test ./..." }], "max_tries": 3, "model": "", "effort": "",
  "next_at": "2026-10-29T02:00:00Z", "last_at": "2026-10-28T02:00:00Z",
  "last_note": "Skipped, because the precheck found no work (exit 1)", "last_run_id": "runraaaaab",
  "created_at": "2026-10-01T09:00:00Z"
}
```

| Command | Output |
| :- | :- |
| `loam recurring add <plot> --title <text> --prompt <text> --kind shape\|chore --days <days> --at <HH:MM> [--precheck <command>] [--if-asleep once\|skip] [--repo <repo>] [--check <name>=<command>]... [--max-tries <n>] [--model <model>] [--effort <level>] [--approve-setup]` | `{ "recurring": {...} }` |
| `loam recurring list [<plot>]` | `{ "recurring": [...] }`, the next due first |
| `loam recurring rm <recurring>` | `{ "recurring": {...} }`, the one that it removed. Its runs stay. |
| `loam recurring run <recurring>` | `{ "recurring": {...}, "run": {...}, "note": "..." }`: it starts the run now, as a tick does. `next_at` stays. |
| `loam tick` | `{ "recurring": [{ "recurring": {...}, "run": {...}, "note": "..." }], "runs": [...], "warnings": [] }` |
| `loam tick install` | `{ "installed": true, "plist": "...", "interval": 300, "last_tick": { "at": "...", "error": "" } }` |
| `loam tick status` | The same |
| `loam tick uninstall` | The same, with `installed` false |

- `--days` is `daily`, `weekdays`, `weekends`, or days such as `mon,wed,fri`. `days` holds them in the order of the week. `at` is the time on the clock of the Mac.
- `kind` `shape` has Claude draft a run in `shaping` from the prompt, as `run shape` does, for you to approve. `kind` `chore` starts a run with the prompt as its goal, as `run start` does, in a new worktree. A chore cannot ask to approve the setup command of the repo: `--approve-setup` on `recurring add` approves it then.
- When a recurring run is due, `loam tick` first moves `next_at` to the next time after the tick. Two ticks at once never start it twice. Then:
  1. A plot that is archived, or a run of the recurring run that has not ended (`source` `kind` `recurring`, `key` its ID), starts nothing: runs never stack. `note` says why, and no run is made.
  2. A time more than 15 minutes late counts as one time that the Mac slept through, however many it missed. With `if_asleep` `skip`, the run is skipped.
  3. The precheck runs with `sh -c` in the repo, for at most 2 minutes. An exit code that is not 0 skips the run. Exit 126 or 127 (the shell could not run the command) says that the precheck could not run its command, with the end of what it printed, not that it found no work. What it prints goes to Claude after the prompt.
  4. A skip makes a run that is `skipped` and starts no session, with the reason in `note`. A skip after a skip changes that run, so a quiet week makes one run.
  5. Else the run starts or Claude shapes it. A failure to start is the `note`, and the tick goes on.
- `last_at`, `last_note`, and `last_run_id` say what the last tick did. `last_at` is left out before the first time.
- After the recurring runs, `loam tick` does what `run tick` does, and `runs` and `warnings` are its result.
- `tick install` writes the launchd agent `~/Library/LaunchAgents/dev.loam.tick.plist`, which runs this loam binary with `tick` every 300 seconds, with the `PATH` and `LOAM_HOME` of the command, and loads it with `launchctl bootstrap`. `tick uninstall` unloads it and removes the file. `installed` is true while the file exists. `last_tick` is the last `loam tick`, with its error, if any. It is left out before the first tick.

### Intake

The intake of a plot is the work that it can start runs from: the open issues of its Linear team and project links, the open issues of its GitHub repos, through `gh`, and the open tickets of the wayfinder maps in its links. A Linear team link is a page such as `https://linear.app/acme/team/ENG/active`. A project link is a page such as `https://linear.app/acme/project/loam-redesign-8f3a2b1c9d0e/overview`. A map is a local link to a file called `map.md`. Its tickets are the `.md` files in the `issues` folder next to it. A ticket file starts with lines such as `Status: open` and `Blocked by: 135`, then a `# Title` line. A ticket whose status is resolved, done, closed, dropped, or wontfix is not open.

| Command | Output |
| :- | :- |
| `loam intake list <plot>` | `{ "plot_id": "...", "sources": [{ "kind": "github", "label": "example/widgets", "error": "" }], "items": [{ "source": "github", "key": "#57", "title": "...", "status": "Open", "priority": "", "labels": ["bug"], "url": "https://github.com/example/widgets/issues/57", "updated_at": "...", "run_id": "runraaaaab", "repo": "repoaaaaab", "text": "...", "branch": "", "created_at": "...", "in_cycle": false, "assigned_to_me": false, "assignee": "ada", "in_progress": false, "milestone": "", "milestone_order": 0 }] }` |

- The items are the Linear issues first, then the GitHub issues, each the newest change first (at most 100 for each link or repo), then the map tickets in number order. A Linear issue is open while its state is not completed or canceled.
- `status` is for a person to read: the Linear state, such as `Todo`, `Open`, or `Blocked by 135` for a ticket.
- `priority` is the Linear priority (`Urgent`, `High`, `Medium`, or `Low`), or empty.
- `url` is what `loam run start` takes: `--link` for an issue, `--ticket` for a ticket.
- `run_id` is the newest run with the item as its `source`, or empty.
- `repo` is the ID of the repo of the plot that a GitHub issue belongs to. It is empty for a Linear issue and a ticket. `run start` and `run shape` with that `--link` use that repo.
- `text` is the first 1200 characters of the Linear description or the GitHub body, trimmed. For a ticket it is the text of the file after its `# Title` line. It is empty when there is none.
- `branch` is the branch name that Linear gives the issue. It is empty for a GitHub issue and a ticket.
- `created_at` is when the issue was made (RFC 3339). For a ticket it is the change time of the file.
- `in_cycle` is true for a Linear issue in the active cycle of its team, else false.
- `assigned_to_me` is true when the Linear assignee is the person of the Linear key, or when the assignees of a GitHub issue include the user of `gh` (`gh api user`, read once for a list). It is false for a ticket.
- `assignee` is the name of the Linear assignee, or the logins of the GitHub assignees joined with ", ". It is "" for no assignee and for a ticket.
- `in_progress` is true for a Linear issue whose workflow state type is `started`, such as In Progress or In Review, else false.
- `milestone` is the name of the project milestone of a Linear issue, or "". `milestone_order` is the `sortOrder` of that milestone in its project, so a lower number comes first. It is 0 for no milestone.
- All nine fields are always there.
- A source that Loam cannot read, such as a repo when `gh` is missing or rate-limited, or a Linear link with no API key, has its `error`, and the other sources still show. The command exits 0.

### Linear

Loam keeps a personal Linear API key in the login Keychain of macOS (service `Loam`, account `linear-api-key`). Only the core reads it.

| Command | Output |
| :- | :- |
| `loam linear status` | `{ "connected": true, "viewer": { "name": "...", "email": "...", "organization": "..." }, "error": "" }` |
| `loam linear key set` | The same, after the key on stdin passed a check with Linear. A key that Linear refuses is not stored (exit code 1). |
| `loam linear key rm` | `{ "connected": false, "viewer": null, "error": "" }` |

- `connected` is true when a key is stored. `viewer` is null when there is no key, or when Linear did not answer, and then `error` says why.
- When a run starts from a Linear issue, Loam moves the issue to the first started state of its team, such as In Progress, unless the issue has started or ended. A `linear` event of the run says what happened. A failure is a warning: the run still starts. The second run of a group finds the issue started, which is not a warning.
- When a run lands, its issue moves to the first completed state, such as Done. For a run of a group, this happens only when every other run of the group has ended as `landed` or `cancelled`. Until then, the `linear` event says why the issue stays, such as "ENG-523 stays In Progress: 1 more run of the issue has not landed". The rule is the same for `run land` and for a tick that lands a run after a merge queue. When you cancel the last run of a group, and another run of the group landed, the issue moves to Done too.
- When a run lands with `notes` and a `pr`, and the `walkthrough_comment` switch is on, Loam adds a comment to its issue: "Landed in #25 by a Loam run. <walkthrough> 3 of 3 checks passed." The checks are those of the last gate of the run. Each run of a group adds its own comment. The `linear` event is "Added the walkthrough to ENG-523 as a comment". A failure is a warning.

**Updates to Linear.** Four switches turn each update that Loam makes to the Linear issue of a run on or off. They hold for every plot. They are not in the change log.

```json
{ "updates": { "in_progress": true, "attach_pr": true, "done": true, "walkthrough_comment": false } }
```

| Command | Output |
| :- | :- |
| `loam linear updates [--in-progress on\|off] [--attach-pr on\|off] [--done on\|off] [--walkthrough on\|off]` | `{ "updates": {...} }` |

- `in_progress`: when a run starts, move the issue to In Progress. On by default.
- `attach_pr`: when Loam opens the PR, attach it to the issue. On by default.
- `done`: when a run lands, move the issue to Done, with the rule for a group above. On by default.
- `walkthrough_comment`: when a run lands, add its walkthrough as a comment. Off by default.
- With no flag, the command prints the switches. A flag sets that switch and leaves the others. A value that is not `on` or `off` exits 2.
- An update that is off makes no call to Linear. For `in_progress`, `attach_pr`, and `done`, the `linear` event says so, such as "Loam did not move ENG-523 to Done: that update to Linear is off".

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
| `loam run hook <run>` | It is hidden. It speaks the Claude Code hook protocol for the session of a run. A failed gate exits 2 with the reason on stderr. |
| `loam setup` | It is interactive. Use `loam setup --check --json` instead. |
| `loam resume <session-id> [--plot <plot>]` | It replaces the process with `claude --resume`. When Claude Code keeps no conversation for the session (no `projects/*/<session-id>.jsonl` in `CLAUDE_CONFIG_DIR`, else `~/.claude`), it runs `claude --session-id` with the same ID instead. Claude Code writes that file at the first prompt, so a session that never had a prompt has none, and `claude --resume` would fail. |

### Home sessions

`loam start --home [--session-id <uuid> | --resume <uuid>]` starts a session that belongs to no plot. The app uses it for Home, its space for tabs with no plot. The session starts in the home folder. It gets no seed, no `--add-dir`, and no `LOAM_PLOT`, but it gets the same settings file as a seeded session, so the pane hooks and the allow rules work. It adds no session record, so `loam sessions` does not list it and `loam resume` does not know it. `--resume` runs `claude --resume` in the home folder, where Claude Code finds the session. When Claude Code keeps no conversation for the session, `--resume` runs `claude --session-id` with the same ID instead, as `loam resume` does.

`--home` with a plot, or with `--repo`, `--worktree`, or `--plot-folder`, exits with code 2 (`invalid`). So do `--resume` without `--home`, `--resume` with `--session-id`, and a value that is not a UUID.

`loam resume <session-id> --plot <plot>` moves a Home session into a plot. The app runs it when you move a Home tab to a plot. When the session has no record, it adds a record in the plot, with the home folder as the start folder, because a Home session always runs there. Then it resumes the session as `loam resume` does: with the seed, the `--add-dir` folders, and `LOAM_PLOT`. It adds the record only when the launch plan is ready, so a failed check leaves no record. When the session is already recorded in that plot, it resumes it. A session with no conversation starts again with `--session-id` and the same ID, as for `loam resume`. When the session is recorded in another plot, it exits with code 2 (`invalid`), so a session never moves between plots. So does a session ID that is not a UUID. An archived plot is refused as for `loam start`. The record writes no change.

### Worktree sessions

`loam start <plot> --worktree <worktree> [--repo <repo>]` starts the session in the worktree, with no `--add-dir` for the normal checkout of its repo. Before the first session in a worktree, it prints "Claude will ask to trust this folder, choose Yes." While `setup_done` is false, it runs the setup command in the worktree before it starts `claude`, and records a success. A failed setup prints a warning, and `claude` still starts. A setup command runs with no question only when you approved that exact text: a command you set with `loam repo add` or `loam repo edit --setup` is approved, and one set through MCP (`add_repo`, `update_repo`) is not. For a new or changed command, `loam start` shows it and asks "Run it? [y/N]" on a terminal; with no terminal it skips the command with a warning. A yes approves the command, and `claude` starts either way. `loam resume` does the same, and fails if the worktree folder is gone. The app starts each worktree pane with `loam start --worktree` or `loam resume`, so each new pane runs setup again until it succeeds.

## Pane socket

The app runs each pane. It sets `LOAM_PANE_SOCKET` in the pane environment to the path of a Unix socket that it listens on. A session that `loam start` or `loam resume` runs in the pane registers `loam hook` for the hook events below. A session outside the app has no `LOAM_PANE_SOCKET`, and `loam hook` sends nothing. An empty value, as the settings of a run set it, is the same as no value.

For each hook event in the table, `loam hook` connects to the socket and writes one line. The line is one JSON object and a newline. Then it closes the connection. The app reads lines until the connection closes. It may get lines from many sessions.

```json
{ "event": "SessionStart", "session_id": "11111111-2222-4333-8444-555555555555", "cwd": "/abs/path", "source": "startup", "at": "2026-10-02T09:00:00Z" }
```

| Field | Meaning |
| :- | :- |
| `event` | The hook event name |
| `session_id` | The Claude Code session ID |
| `cwd` | The working folder that Claude Code reports |
| `source` | On `SessionStart`: `startup`, `resume`, `clear`, `compact`, or `fork`. On `UserPromptSubmit`: what started the turn, as Claude Code says it, such as `user` for a prompt that you sent and `system` for a turn that Claude Code starts by itself. Claude Code does not send it on `UserPromptSubmit` today, and the line then has none. No other event has it. |
| `notification_type` | Only on `Notification`: `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `permission_prompt`, `elicitation_response`, or `elicitation_complete` |
| `at` | The time of the hook call, in UTC |

| Event | When |
| :- | :- |
| `SessionStart` | A session starts, resumes, clears, compacts, or forks |
| `SessionEnd` | A session ends |
| `UserPromptSubmit` | A turn starts: you send a prompt, or Claude Code starts the turn (see `source`). The line does not hold the prompt. |
| `Stop` | Claude finishes its turn |
| `PermissionRequest` | Claude asks you to allow a tool |
| `Notification` | Claude needs your input, or a question closed. Only the six types above raise a line. `elicitation_response` says that you answered an MCP question, and `elicitation_complete` that a URL question ended. `idle_prompt` and other types raise nothing. |
| `PostToolUse` | A tool call ends. The line does not hold the tool input or output. |
| `PostToolUseFailure` | A tool call fails, such as a Bash command with a non-zero exit, or you stop it with Escape. The line does not hold the tool input or the error. |
| `StopFailure` | A turn ends with an API error |

A subagent stop (`SubagentStop`) raises nothing.

- The app must ignore events and fields that it does not know. A later version adds events with no change of the contract version.
- `loam hook` never fails and never blocks. It waits at most 200 ms to connect and 200 ms to write. When the socket is missing, dead, or slow, it drops the line, writes the error to `hook.log` in the Loam home folder, and exits with code 0.
- The event table is `paneEvents` in `core/internal/session/panesocket.go`.
- On a `SessionStart` with a session ID, with or without the socket, `loam hook` also records the session ID for the `CLAUDE_PID` of the claude process. It does this only when `CLAUDE_PID` is a positive number and the store exists. On source `clear`, `resume`, or `fork`, it adds a session record for the new ID. The plot is `LOAM_PLOT`, or the plot of the earlier session when that is empty. It adds nothing when the earlier session of the process has no record. Source `fork` comes from the `/branch` command, which keeps the process and gives the session a new ID. A fork that starts a new process, such as `--fork-session`, has no earlier session for its PID, so it adds nothing.

## Store migrations

Each schema step of the store goes forward only. `store.SchemaVersion` is the schema of a program, and the table `schema_version` holds the schema of a store. A program migrates an older store when it opens it.

**The copy.** Before a program migrates a store that has a schema, it writes a copy beside the store: `<LOAM_HOME>/loam.db.v<old>.bak`, where `<old>` is the schema of the store.

- Loam writes the copy with `VACUUM INTO`, so the copy holds what the WAL holds. The copy is a complete database at the old schema, and it is private to the user.
- A store with no schema yet gets no copy. A store at the schema of the program gets no copy.
- Loam reads the schema of the copy before it puts the copy in place. Another program can migrate the store before the copy starts. Loam then discards the copy, keeps the earlier copy of that name, and reads the schema of the store again.
- When the copy fails, the migration does not run, the store does not change, and the command fails. The error names both schemas, the path of the copy, and the reason.
- A new copy replaces an earlier copy of the same schema. Loam keeps the 3 newest copies by file time, and removes older ones. Loam does not read the copies. To go back, quit Loam and each session, then replace `loam.db` with a copy, and remove `loam.db-wal` and `loam.db-shm`.

**The refusal.** A dev build refuses to migrate a store that has a schema, in the default home `~/.loam`. The installed release could not write to the store after the migration. The command fails with kind `error`, the store does not change, and Loam writes no copy. The error names both schemas and the two ways past it.

- A release version is the form that `scripts/release.sh` accepts: `vMAJOR.MINOR.PATCH`, as `loam version` prints it. Any other version is a dev build: `dev`, a Go pseudo version, and the `git describe` form of `scripts/install.sh` or `scripts/update.sh` away from a tag, such as `v0.4.6-8-g46e28bbf` or `v0.4.6-dirty`.
- A dev build migrates when `LOAM_HOME` moves the home to another folder. A `LOAM_HOME` that names `~/.loam`, or a link to it, does not move the home, because a run session has `LOAM_HOME` set to the home of its store.
- A dev build migrates any home when `LOAM_ALLOW_DEV_MIGRATE=1`.
- A dev build makes a new store in the default home, and it opens a store at its own schema, or at a newer schema.

**A newer store.** A program opens and reads a store that is newer than the program, and each write fails. The error names both schemas and both fixes:

- A session that outlived an update runs the old program: restart the session.
- An installed release that a dev build overtook: update Loam with `scripts/install-release.sh`. When no release has the schema of the store yet, go back to a copy.

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
