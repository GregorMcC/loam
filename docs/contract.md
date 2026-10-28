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

- `checks` lists each check that blocks the land, in the order of the land result. See [Land, rerun, and update](#land-rerun-and-update). The list is empty when `--head` names another commit than the PR head: no check blocks, and the message says that the PR has new commits.

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

`loam worktree list` shows the pull request (PR) of the branch of each worktree, from GitHub only. Without `--refresh`, it reads the PR cache in the store and does not use the network. `--refresh` asks GitHub first and writes the cache. `--worktree <worktree>` refreshes only that worktree (an ID, a folder name, or a name); the output still lists every worktree. `--worktree` needs a plot and `--refresh`, and `--repo` needs `--worktree`. Each other use exits with code 2. MCP `list_worktrees` takes `refresh` (a boolean) and does the same as `--refresh`. Its result is the same JSON as `loam worktree list --json`, except that the `pr` of a worktree leaves out `passed_checks`. A session reads the passed checks through gh, and up to 100 rows for each worktree would fill its context. `checks.passed` still counts them.

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
  "passed_checks": [{ "name": "test / macos-26", "url": "https://github.com/...", "duration": 190, "required": true, "run_id": 1235 }]
}
```

- `state` is `OPEN`, `CLOSED`, or `MERGED`. `mergeable`, `merge_state` (GitHub's `mergeStateStatus`), and `review_decision` are the values of GitHub. `review_decision` is empty when the base branch needs no review.
- `merged_at` and `closed_at` are present when the PR is merged or closed.
- `queue_position` counts from 1. It is 0 when the PR is not in the merge queue.
- `behind_base` counts the commits of the base branch that the head does not have. `approvals` counts the reviewers with write access whose last review approves. `comments` counts the review threads that are not resolved.
- `checks` counts the checks of the head commit. `checks.state` is GitHub's summary, empty when the head has no checks. A cancelled or stale check counts only in `total`. `required` counts the checks that the base branch needs to pass before a merge, and `required_passed` counts those that passed. For an `UNSTABLE` PR, the app can write "14 of 14 required checks passed · 2 optional failed".
- `failed_checks` lists each failed check. A GitHub Actions job has its workflow name first. `duration` is in seconds, 0 when GitHub gives no start or end. `required` is true for a required check. `run_id` is the GitHub Actions run of the check, which `loam worktree rerun` runs again. It is left out for a check that is not a job of GitHub Actions.
- `passed_checks` lists each passed check, with the same fields as a failed check. A skipped or neutral check counts as passed, as in `checks.passed`, so the list is as long as `checks.passed`. The order is the order of GitHub. A cache row from before Loam stored the passed checks gives an empty list until the next refresh. MCP `list_worktrees` leaves the field out.
- Loam reads one page of 100 checks and 100 review threads, to keep to two queries for each repo. `checks.total` counts every check. The other check counts, `failed_checks`, `passed_checks`, and `comments` cover the first 100.
- `behind_base`, `approvals`, `comments`, `checks`, `failed_checks`, and `passed_checks` are for an open PR. They are 0 or empty for a merged or closed PR. `failed_checks` and `passed_checks` are always lists, never null.

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
- `worktree` has the `land` that the worktree records after the land. It has no `land` after the tidy up of a merge, and after a removal. When the tidy up waits for open panes (step 6), it has the `land` that the land recorded.
- `land_note` says that the worktree recorded a `land` of another PR (see below).
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
   - With `--head <commit>` and an open PR, a land that is not a dry run stops when the PR head is another commit: exit code 16 (`not_ready`) with no check in `checks`, and the message "PR #12 has new commits since you looked at it. Look again before you merge". It changes nothing and calls no action of gh. The app passes the head of the plan that its Land sheet shows, so a commit that GitHub got after the sheet read the PR is never merged unseen. A dry run and a merged PR ignore `--head`. A value that is not a full commit ID exits with code 2.
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
  "state": "running", "tries": 1, "max_tries": 3,
  "source": { "kind": "github", "key": "#57", "url": "https://github.com/example/widgets/issues/57" },
  "pr": { "number": 147, "url": "https://github.com/example/widgets/pull/147" },
  "session_id": "c57ef956-3136-4e86-bfde-da8facfe0523", "note": "Try 1 failed: Go tests",
  "created_at": "2026-10-02T09:00:00Z", "updated_at": "2026-10-02T09:04:00Z"
}
```

- `state` is one of these:
  - `shaping`: it waits for you to approve its goal and checks.
  - `starting`: Loam is starting its session.
  - `running`: its session works, or the gate or CI sent failures back.
  - `shipping`: every check passed, and the repo is on GitHub. `loam run tick` pushes the branch, opens the PR, and reads CI.
  - `ready`: it waits for you to land it. Every check passed, and CI passed on its PR, or it has no PR. `note` says which.
  - `stopped`: it used all its tries, or a failure stopped it.
  - `limited`: Claude Code hit a usage limit (Stopped by a limit). It counts no try.
  - `start_unknown`: `claude --bg` did not return in time. The session may exist.
  - `landed`, `cancelled` (stopped by you), and `skipped` (a recurring run found no work).
- `shaping`, `stopped`, and `limited` need you.
- `tries` counts the failed gates and the CI failures. `max_tries` is 1 to 8, because Claude Code lets a session stop after 8 blocked stops in a row.
- `session_id` is empty until the SessionStart hook of the session records it. `claude --bg` picks its own session ID. `claude attach`, `logs`, and `stop` take its first 8 characters.
- `pr` is the PR that Loam opened for the run, or the open PR of its branch that Loam found. It is left out before the run ships.
- `source` is the issue of the worktree's link, or the map ticket that `--ticket` names (`kind` `map`, `key` such as `map 135`, `url` the path of the ticket file). It is left out when there is none.

The gate is the Stop hook of the session. Each time the session ends a turn, Loam runs each check with `sh -c` in the folder, then checks that `git status --porcelain` is empty ("Work committed"). When all pass, the run is `shipping` when the origin of its repo is on GitHub, else `ready`. When one fails, the try counts. With tries left, the hook exits 2 and the failures go back to the session as its next prompt. With no tries left, the session stops and the run is `stopped`.

| Command | Output |
| :- | :- |
| `loam run start <plot> --title <text> [--goal <text>] [--check <name>=<command>]... [--worktree <name>] [--repo <repo>] [--base <branch>] [--link <link-id or URL> \| --ticket <file>] [--max-tries <n>] [--model <model>] [--approve-setup]` | `{ "run": {...}, "worktree": {...} }` |
| `loam run list [<plot>]` | An array of runs, newest first. It is `[]` when none exists. |
| `loam run status <run>` | `{ "run": {...}, "events": [{ "id": 1, "run_id": "...", "at": "...", "kind": "state", "detail": "running" }] }`. `kind` is `state`, `try`, `check`, `linear`, `ship`, `ci`, `review`, `note`, `land`, `shape`, or `draft`. |
| `loam run stop <run>` | `{ "run": {...} }`. The run is `cancelled`. A run that has ended stays as it is. |
| `loam run tick` | `{ "runs": [...], "warnings": ["..."] }`. `runs` are the runs that the tick moved. Both are `[]` when none. |

`run start` uses the worktree that `--worktree` names, or makes it. With no `--worktree`, it makes a worktree with a name from the key of the link or the ticket, and the title. A run has `--link` or `--ticket`, not both (exit code 2). It refuses, with exit code 1, a folder that Claude Code does not trust: a background session cannot show the trust prompt. In git, Claude Code trusts a worktree when it trusts the main checkout of the repo. A setup command that you have not approved gives exit code 2 (`invalid`); `--approve-setup` approves it. When `claude --bg` fails, the run is `stopped` with the output in `note`, and the command exits 0.

#### Ship

`loam run tick` moves on each run in `shipping`. A tick that waits on GitHub changes nothing, so the app runs it often while a run ships. Only one tick runs at a time: a second one prints the empty result at once. For each run, the tick does the first step that applies:

1. The run's worktree is gone, or the origin is not on GitHub: the run is `ready`, and `note` says why. gh missing or signed out makes it `ready` too, with the error in `note`.
2. GitHub has the run's PR merged: the run is `landed`, with a `land` event, and its Linear issue moves to Done. Closed: the run is `stopped`.
3. An open PR of the branch that is not the run's PR: it becomes the run's PR (event `ship`, "Found #12, the open PR of the branch").
4. The head of the worktree is not the PR head: the tick runs `git push -u origin <branch>` when `origin/<branch>` is not the head. A failed push stops the run with the output in `note`. With no PR, it runs `gh pr create` with the title of the run, the base of the worktree, and a body with the goal, the Done when checks, and the issue (`Closes #57` for a GitHub issue, the key, such as `Linear: ENG-523`, for a Linear issue). It names no local path and no Linear URL, because the repo can be public and the Linear workspace private. The events are `ship`: "Opened #12", or "Pushed the fix to #12". For a Linear issue, Loam attaches the PR to it (event `linear`). A failed attach is a warning.
5. CI on the PR head:
   - No checks: the run waits 3 minutes after the push, then is `ready` ("No CI ran on #12").
   - A failed check: the try counts. With tries left, the run is `running` and Loam sends the session a prompt with each failed check and the last 60 lines of its failed log (`gh run view <id> --log-failed`). Loam runs `claude stop` and then `claude --bg --resume <session ID> "<prompt>"` with no other flag, so the session wakes with its own options and hooks. The next gate that passes ships the fix to the same PR. With no tries left, the run is `stopped`.
   - Checks that run or wait: nothing changes.
   - All passed: the run is `ready` ("CI passed on #12: 14 of 14 checks").

Each CI result is a `ci` event.

A tick also watches the PR of each run that is `ready` and has a `pr`. A merge on GitHub lands the run, as in step 2, and a close stops it. A run that cannot reach GitHub waits with no warning.

#### Land

| Command | Output |
| :- | :- |
| `loam run diff <run>` | `{ "base": "<commit>", "head": "<commit>", "files": [{ "path": "README.md", "status": "modified", "added": 3, "deleted": 1, "hunks": [{ "header": "@@ -1 +1,3 @@", "old_start": 1, "new_start": 1, "lines": [{ "kind": "del", "old": 1, "text": "hello" }, { "kind": "add", "new": 1, "text": "# Loam" }] }] }] }` |
| `loam run send-back <run> --note <text>...` | `{ "run": { ... }, "rule_offer": { "note": "...", "earlier": "...", "earlier_run_id": "...", "earlier_title": "..." } }` |
| `loam run land <run> [--head <commit>] [--keep-worktree] [--open-pane <folder>]... [--dry-run]` | `{ "run": { ... }, "land": { ... }, "warnings": [] }` |

- `run diff` is the work that the run committed: from `base`, the commit where its branch left the base of its worktree, to `head`. `status` is `added`, `modified`, `deleted`, or `renamed`, with `old_path` for a rename. A binary file has `binary` and no hunks. A file keeps at most 3000 lines and then has `truncated`; `added` and `deleted` count every line. A line has `old`, `new`, or both: the numbers of the line before and after the change.
- `run send-back` takes a run that is `ready` or `stopped`, and at least one note. A note is `<file>:<line>: <text>` for a line, or text alone. Loam stops the session and resumes it with the notes as its prompt, as for a CI failure, and the run is `running` ("Sent back with 2 notes", event `review`). A note uses no try. A run with no tries left gets one more (`max_tries` goes up by 1, to at most 8). The next gate that passes ships the change to the same PR. Each note is an event `note`: `<file> line <n>: <text>`, or the text alone.
- `rule_offer` is there when a note is like a note on another run of the plot: they share at least 2 words, and at least half of all their words, when Loam leaves out short and common words. A note like the `note` of a rule of the plot gets no offer. `note` and `earlier` are the texts of the two notes, and `earlier_run_id` is the other run. The app offers to make the note a rule with `loam rule add`.
- `run land` takes a run that is `ready` and has a `pr`. Loam checks the land first with a dry run. When the land can go on, Loam stops the session, because the land removes the worktree. A land that refuses keeps the session. Loam then lands the worktree as `loam worktree land` does, with the default merge method: `land` is the `worktree land` result. A merge makes the run `landed` ("Merged #25 with squash", event `land`), and its Linear issue moves to the first completed state (event `linear`). With a merge queue, the run stays `ready` ("#25 is in the merge queue of main"), and a tick lands it when GitHub merges. `--dry-run` changes nothing, and `land` is the plan.
- A run in another state, or with no PR, exits 2. A check that blocks the merge exits 16, and gh missing or signed out exits 17, as for `worktree land`.

#### Shape

| Command | Output |
| :- | :- |
| `loam run shape <plot> --title <text> [--repo <repo>] [--base <branch>] [--link <link> \| --ticket <file>] [--max-tries <n>] [--model <model>]` | `{ "run": { ..., "state": "shaping", "shape": { "assumptions": [{ "text": "...", "answer": "" }], "plan": ["..."], "size": "...", "drafted_at": "...", "repo": "repoaaaaag", "base": "", "link": "", "model": "" } } }` |
| `loam run redraft <run> [--change <text>]` | `{ "run": { ... } }` |
| `loam run approve <run> [--goal <text>] [--check <name>=<command>]... [--no-checks] [--answer <n>=<text>]... [--approve-setup]` | `{ "run": { ... }, "worktree": { ... } }`, as for `run start` |

- `run shape` records a run that is `shaping`, with the repo as its `folder` and no worktree, then has Claude draft it: `claude -p` in the repo, with the tools Read, Grep, and Glob only, `--output-format stream-json --verbose`, a `--json-schema`, and `--no-session-persistence`. The prompt holds the title and the text of the issue: the ticket file, `gh issue view`, or the Linear issue. The draft sets `goal` and `done_when`, and `shape` holds the rest (event `shape`). The command can take minutes. While Claude drafts, each step that it takes is an event `draft`, such as `Read window/frame.go`, `Searched for SaveFrame`, or the first line of its text, up to 100 steps for one draft. The app reads them to show the draft as it happens.
- While Claude drafts, the `note` is "Claude is drafting the run". A run that Claude has not drafted yet has no `drafted_at`. A first draft that fails keeps the run `shaping` with no `drafted_at`, and the `note` says why ("Claude could not draft the run: ..."). The command exits 0.
- `run redraft` drafts a `shaping` run again. `--change` is what you want changed: Claude gets its last draft and the change.
- `run approve` takes a `shaping` run that has a draft. Loam makes the worktree, as `run start` does with the `repo`, `base`, and `link` of the shape, and starts the session. `--goal` and `--check` replace the draft's, and `--no-checks` removes the draft's checks (it exits 2 with `--check`). `--answer` sets the `answer` of an assumption, by number from 1. The session prompt holds the assumptions, with your answer in place of an assumption that you changed, and the plan. A run in another state, a run with no draft, or an answer to no assumption exits 2.
- `run stop` on a `shaping` run cancels it, with no `claude stop`.
- The `shape` of a run that a recurring run shaped has a `brief`: the prompt of the recurring run and what its precheck printed. Claude drafts from it, as from the text of an issue.

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

- The gate runs the rules of the plot after the checks of the run, each as the check `Rule: <name>`, with `sh -c` in the folder of the run. A rule that fails blocks the stop as a check does. The session prompt lists the rules with the checks.
- `note` is the note that the rule came from. A note like it gets no `rule_offer`.
- A name or a command that is empty exits 2.

#### Recurring

A recurring run starts on a timetable, such as weekdays at 06:30, when its precheck finds work (ticket 208). `loam tick` starts it when it is due. Recurring runs are not in the change log, as runs are not.

```json
{
  "id": "recuaaaaab", "plot_id": "k3v9q2mxa7", "title": "Bump Go dependencies", "prompt": "Bump the Go modules that have updates.",
  "kind": "chore", "days": ["mon", "tue", "wed", "thu", "fri"], "at": "02:00",
  "precheck": "go list -m -u all | grep -q '\\['", "if_asleep": "once", "repo": "",
  "done_when": [{ "name": "Go tests", "command": "go test ./..." }], "max_tries": 3, "model": "",
  "next_at": "2026-10-29T02:00:00Z", "last_at": "2026-10-28T02:00:00Z",
  "last_note": "Skipped, because the precheck found no work (exit 1)", "last_run_id": "runraaaaab",
  "created_at": "2026-10-01T09:00:00Z"
}
```

| Command | Output |
| :- | :- |
| `loam recurring add <plot> --title <text> --prompt <text> --kind shape\|chore --days <days> --at <HH:MM> [--precheck <command>] [--if-asleep once\|skip] [--repo <repo>] [--check <name>=<command>]... [--max-tries <n>] [--model <model>] [--approve-setup]` | `{ "recurring": {...} }` |
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
| `loam intake list <plot>` | `{ "plot_id": "...", "sources": [{ "kind": "github", "label": "example/widgets", "error": "" }], "items": [{ "source": "github", "key": "#57", "title": "...", "status": "Open", "priority": "", "labels": ["bug"], "url": "https://github.com/example/widgets/issues/57", "updated_at": "...", "run_id": "runraaaaab" }] }` |

- The items are the Linear issues first, then the GitHub issues, each the newest change first (at most 100 for each link or repo), then the map tickets in number order. A Linear issue is open while its state is not completed or canceled.
- `status` is for a person to read: the Linear state, such as `Todo`, `Open`, or `Blocked by 135` for a ticket.
- `priority` is the Linear priority (`Urgent`, `High`, `Medium`, or `Low`), or empty.
- `url` is what `loam run start` takes: `--link` for an issue, `--ticket` for a ticket.
- `run_id` is the newest run with the item as its `source`, or empty.
- A source that Loam cannot read, such as a repo when `gh` is missing or rate-limited, or a Linear link with no API key, has its `error`, and the other sources still show. The command exits 0.

### Linear

Loam keeps a personal Linear API key in the login Keychain of macOS (service `Loam`, account `linear-api-key`). Only the core reads it.

| Command | Output |
| :- | :- |
| `loam linear status` | `{ "connected": true, "viewer": { "name": "...", "email": "...", "organization": "..." }, "error": "" }` |
| `loam linear key set` | The same, after the key on stdin passed a check with Linear. A key that Linear refuses is not stored (exit code 1). |
| `loam linear key rm` | `{ "connected": false, "viewer": null, "error": "" }` |

- `connected` is true when a key is stored. `viewer` is null when there is no key, or when Linear did not answer, and then `error` says why.
- When a run starts from a Linear issue, Loam moves the issue to the first started state of its team, such as In Progress, unless the issue has started or ended. A `linear` event of the run says what happened. A failure is a warning: the run still starts.

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
