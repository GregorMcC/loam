# The loam CLI

The core works in any terminal, without the app. The app uses the same commands. Each command that prints data takes `--json` for machine-readable output, and the [contract](contract.md) describes that output. `loam <command> --help` shows every flag.

## Install only the CLI

You need Go 1.26 or later and Claude Code:

```sh
scripts/install.sh core                       # builds loam into ~/.local/bin
loam setup                                    # registers the Loam MCP server with Claude Code
```

## A first plot and a first run

```sh
loam new "Checkout"                           # opens the brief in $EDITOR
loam repo add "Checkout" ~/Code/storefront
loam link add "Checkout" Design ~/Notes/Checkout/design.md

loam start "Checkout"                         # a seeded Claude Code session in the main repo

loam run shape "Checkout" --title "Apple Pay button misaligned" \
  --link https://github.com/acme/storefront/issues/57
loam run list "Checkout"                      # find the run ID, then read the draft
loam run approve <run>                        # start it
loam tick install                             # let launchd move runs on every 5 minutes
```

## Plots

| Command | Does |
| :- | :- |
| `loam list` / `loam show <plot>` | See your plots, and one plot in full |
| `loam new <name>` / `loam edit <plot>` | Make a plot, or edit its name and brief, in `$EDITOR` |
| `loam set <plot> where-it-stands "..."` | Move the brief on. Also `name`, `what`, and `why`. |
| `loam repo add <plot> <path>` | Add a repo. `loam repo main` makes a repo the main repo. `loam repo edit` and `loam repo rm` change it. |
| `loam link add <plot> <label> <target>` | Add a link. `loam link edit` and `loam link rm` change it. `loam open <plot> <link>` opens it: browser, Obsidian, Finder, or the default app. A local link that a session added or last changed is not an added folder until you change its label, target, or note. |
| `loam changes` / `loam undo <change-id>` | Review the change log, and undo one change |
| `loam move <plot> <n>` | Move a plot in the plot order |
| `loam archive <plot>` / `loam unarchive <plot>` | Put a finished plot away, or bring it back. `loam delete` removes an archived plot. |
| `loam export [--changes]` | Write the plots, and the change log, as JSON |

## Sessions

| Command | Does |
| :- | :- |
| `loam start <plot> [--worktree <name>]` | Start a Claude Code session that is seeded with the plot. `loam start --home` starts one with no plot. |
| `loam sessions` / `loam resume <id>` | Find a seeded session, and resume it |

## Runs

| Command | Does |
| :- | :- |
| `loam run shape <plot> --title <text>` | Have Claude draft a run for you to approve. `--link` or `--ticket` names the issue. `--split` drafts one run for each repo of the plot. |
| `loam run approve <run>` | Start a Shaping run, with your edits: `--goal`, `--check <name>=<command>`, `--answer <n>=<text>` |
| `loam run redraft <run> --change <text>` | Have Claude draft a Shaping run again with your change |
| `loam run start <plot> --title <text>` | Start a run now, with the goal and the checks that you give. It skips Shape. |
| `loam run list [<plot>]` / `loam run status <run>` | See the runs, and one run with its history |
| `loam run events [--since <time>] [--plot <plot>]` | The run events of every plot, newest first |
| `loam run diff <run>` | The work that a run committed on its branch |
| `loam run send-back <run> --note <text>...` | Resume a Ready, Shipping, or Stopped run with your notes. A note can name a line: `<file>:<line>: <text>`. |
| `loam run send-review <run>` | Resume a Ready run with the review of its PR: the open threads and the reviews that request changes. The text of a reader stays out. `--dry-run` says what it would send. |
| `loam run land <run>` | Merge the PR of a Ready run. `--keep-worktree`, `--no-linear-done`, and `--where-it-stands` change the steps after the merge. `--dry-run` lists each check. |
| `loam run cancel <run>` | Cancel a run: Loam stops its session, and the run is Cancelled. A Cancelled run cannot go back. The worktree and its work stay. `loam run stop` is the old name. |
| `loam run limits` | Show or set the limits: `--at-a-time`, `--max-turns`, `--hold-at` |
| `loam run defaults <plot>` | Show or set the model and the effort of the runs of a plot |
| `loam run sandbox [<plot>]` | Show or set the paths and hosts that you add to the sandbox of a run: `--read`, `--write`, `--host`. With no plot, they hold for every plot |
| `loam run mcp-servers` | List the MCP servers that `loam run defaults --mcp` can select |
| `loam usage [--refresh]` | Show the last usage that Claude Code reported: the 5-hour and 7-day windows |

## Intake, rules, and recurring runs

| Command | Does |
| :- | :- |
| `loam intake list <plot>` | The open issues and tickets of a plot, and the run that started from each |
| `loam rule add <plot> --name <name> --command <command>` | Add a check that every run of the plot must pass. `loam rule list` and `loam rule rm` manage them. |
| `loam recurring add <plot> --title <text> --prompt <text> --kind shape\|chore --days <days> --at <HH:MM>` | Add a run on a timetable. `--precheck` decides whether there is work. `--if-asleep once\|skip` says what happens to a time that the Mac slept through. |
| `loam recurring list [<plot>]` / `loam recurring rm <recurring>` | See and remove recurring runs. Their runs stay. |
| `loam recurring run <recurring>` | Start a recurring run now, with its precheck |

## The tick

| Command | Does |
| :- | :- |
| `loam tick` | Start the recurring runs that are due, and ship the runs whose checks passed |
| `loam run tick` | Ship the runs whose checks passed, and start the queued runs |
| `loam tick install` / `loam tick uninstall` | Have launchd run `loam tick` every 5 minutes while you are logged in, or stop it |
| `loam tick status` | Say whether launchd runs the tick, and when the last tick was |

## Linear

| Command | Does |
| :- | :- |
| `loam linear key` | Read a personal API key on stdin, check it with Linear, and store it in the Keychain. `loam linear key rm` removes it. |
| `loam linear status` | Say whether Loam has a key, and check it |
| `loam linear updates` | Show or set each update that Loam makes to Linear: `--in-progress`, `--attach-pr`, `--done`, `--walkthrough`, each `on` or `off` |

## Worktrees

| Command | Does |
| :- | :- |
| `loam worktree new <plot> <repo> <name> --goal "..."` | Make a worktree for one task, then `loam start <plot> --worktree <name>`. `--link` takes a plot link ID or an issue URL. |
| `loam worktree list [<plot>] --refresh` | See the PR, the checks, and the stage of each worktree. It needs `gh`. |
| `loam worktree land <plot> <worktree>` | Merge the PR, delete the branch, and remove the worktree. It refuses to remove a worktree that has an open pane. `--auto` lets GitHub merge later. `--dry-run` lists each check. |
| `loam worktree rerun <plot> <worktree>` | Run the failed checks of the PR again |
| `loam worktree update <plot> <worktree>` | Bring the PR up to date with its base branch |
| `loam worktree rm <plot> <worktree>` | Remove a worktree |
| `loam repo edit <plot> <repo> --after-merge ask\|remove\|keep` | Choose what the app does when GitHub merges a PR of the repo |

## Setup

| Command | Does |
| :- | :- |
| `loam setup` | Register the Loam MCP server with Claude Code, and trust the plots folder. It prints allow rules for the Loam read tools. |
| `loam version` | Print the loam version and the contract version |
| `loam mcp` | Run the Loam MCP server on stdin and stdout. Claude Code starts it. |
