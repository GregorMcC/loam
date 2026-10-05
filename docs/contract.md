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

Every write also takes `--expect <item>=<version>`, once for each item the caller read. Items are `name`, `what`, `why`, `where`, `link:<id>`, and `repo:<id>`. The versions are in `versions` of a plot, and in `version` of each link and repo. Without `--expect`, a write goes over the latest value.

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
- `exists` is false when the item is gone. A stale link or repo has `link` or `repo` with the current object. A stale `name`, `what`, `why`, or `where` has `value`.

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
- `versions` maps each item to the ID of the change that last set it. Pass these as `--expect`.
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

A worktree is a separate checkout of one repo of a plot, on its own branch. It lives in `<loam home>/worktrees/<plot-id>/<repo folder>-<name>/`. Making or removing one is not a change in the change log.

```json
{
  "id": "wtreeaaaab", "plot_id": "k3v9q2mxa7", "repo": "/abs/path/of/repo", "name": "fix-login", "branch": "fix-login",
  "base": "origin/main", "path": "/abs/path/of/worktree", "setup_done": false, "created_at": "2026-10-02T09:00:00Z"
}
```

- `name` is the branch name. `base` is the branch that a new branch started from. It is empty when the branch existed.
- `setup_done` is true after the setup command has succeeded in the worktree.

| Command | Output |
| :- | :- |
| `loam worktree new <plot> <repo> <name> [--base <branch>]` | `{ "worktree": {...}, "copied": ["relative/path"] }` |
| `loam worktree list [<plot>]` | An array of worktree states, oldest first. It is `[]` when none exists. |
| `loam worktree rm <plot> <worktree> [--repo <repo>] [--force] [--open-pane <folder>]` | `{ "worktree": {...}, "branch_deleted": false, "branch_note": "..." }` |

`new` uses the branch if it exists. Otherwise it fetches from `origin` and starts a new branch, with no upstream, from `--base` or from the default branch of `origin`. A `--base` that names a local branch uses the local branch; `--base origin/<branch>` uses the remote branch. A failed fetch is a warning on stderr. It copies the files of the repo setting `copy` and of `.worktreeinclude` in the repo root (one path or glob for each line, relative to the repo root). It never overwrites a file and never runs the setup command. `<repo>` is a repo ID or a path.

A worktree state, an item of `list`:

```json
{ "worktree": {...}, "missing": false, "changed": 0, "unpushed": 0, "merged": true, "merged_into": "origin/main" }
```

- `changed` counts the files with uncommitted changes, untracked files included. `unpushed` counts the commits that no remote branch holds. `merged` is true when the branch holds nothing that `merged_into` lacks. `merged_into` is left out when no branch to check against is known.
- The checks read the last fetched state. `error` is present when a check failed. `missing` is true when the folder is gone.

`rm` takes a worktree ID, a folder name such as `web-fix-login`, or a name. It exits with code 1 and removes nothing in these cases:

- A pane is open in the worktree. The app passes the folder of each open pane with `--open-pane` (repeatable). The core also reads the panes in `state.json`. `--force` does not skip this check.
- The worktree has uncommitted changes or unpushed commits, and `--force` is missing.

It deletes the local branch with `git branch -d`, so `branch_deleted` is false and `branch_note` says why when the branch is not merged. `branch_note` is left out when the branch was deleted. It never deletes a remote branch.

`state.json` is in `~/Library/Application Support/Loam/`, where the app keeps its state (`LOAM_APP_STATE_DIR` replaces the folder in tests). Its minimal shape is below. A missing file means no open panes. The app writes the panes that it has open or has saved and not yet resumed. The app can add other fields; the core ignores them.

```json
{ "panes": [{ "plot_id": "k3v9q2mxa7", "folder": "/abs/path/of/the/pane/working/folder" }] }
```

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

- Items are `name`, `what`, `why`, `where`, `link:<id>`, and `repo:<id>`.
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

### Commands without JSON output

| Command | Why |
| :- | :- |
| `loam start` | It replaces the process with `claude`. `--repo` takes a repo ID or a path. `--plot-folder` starts in the plot folder of a plot with repos, and every repo is then an added folder; it fails with exit code 2 (`invalid`) with `--repo` or `--worktree`. An unknown repo exits with code 1, as in `loam repo edit`. Each local link adds its folder (or the folder of the file) with `--add-dir`, except the root, the home folder, and a parent of the home folder: a link to one of them adds nothing. |
| `loam mcp` | It speaks the MCP protocol on stdio. |
| `loam hook` | It is hidden. It speaks the Claude Code hook protocol. |
| `loam setup` | It is interactive. Use `loam setup --check --json` instead. |
| `loam resume <session-id>` | It replaces the process with `claude --resume`. |

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
