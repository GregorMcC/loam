# Seeded sessions start in the main repo

A seeded session for a plot with repos starts in the plot's main repo. The plot folder, which holds the seed `CLAUDE.md`, and the plot's other repos attach with `--add-dir`. Loam sets `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` on every launch so the seed loads from the added plot folder. A plot with no repos starts in its plot folder.

The seeding research recommended the opposite: always start in the plot folder, so the seed is the project-root `CLAUDE.md` and auto memory is per plot. We rejected that because Claude Code applies only the start folder's settings. A repo that is only an added folder loses its permissions, hooks, env, `.mcp.json`, and git status, and Bash returns to the start folder on each call. Most plots with repos are coding work, and that loss costs more than per-plot memory. The plot itself holds the knowledge that must cross sessions, so auto memory that follows the repo is acceptable.

## Consequences

- Auto memory and the resume list for a plot with repos belong to the main repo, shared with work in that repo outside Loam.
- A plot with repos marks exactly one main repo. A new pane can start in any other repo of the plot, so Loam stores each session's start folder.
- The docs do not say whether `/compact` re-injects a `CLAUDE.md` from an added folder. Loam adds a SessionStart hook on `compact` that adds the seed again.
- Only the start folder's repo shows git status. Other repos of the plot are file access plus their `CLAUDE.md`, skills, commands, and agents.
