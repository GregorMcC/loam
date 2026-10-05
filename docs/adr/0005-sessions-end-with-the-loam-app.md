# Seeded sessions end with the Loam app

A pane's process is a child of the Loam app. When the app quits or crashes, its seeded sessions end. On the next launch, the app restores the layout, and each session pane runs `loam resume <session-id>` when its plot is first shown. The app asks before it quits if a session is working or needs you.

We chose this over 2 ways to keep sessions alive. Claude Code's own background sessions (`claude --bg` and `claude attach`) survive the app, and their hooks fire with no terminal attached. We rejected them because `--bg` ignores `--session-id`, which the pane start in ADR 0004 needs. A background session also moves into its own worktree under `.claude/worktrees/` before it edits a repo, which clashes with Loam's worktrees and with ADR 0003. The feature is also new. A Loam session daemon that holds each pty, like Supacode's zmx, had the highest build cost. Resume was cheap, and tests showed that an idle session comes back intact.

## Consequences

- A turn in progress at a quit or crash loses its partial reply. Its prompt is kept.
- The store keeps a session record for each session ID: the plot, the session ID, and the start folder. `loam resume` builds the other launch arguments from the current plot.
- `/clear` and an in-session `/resume` change the session ID, so a `SessionStart` hook records each new ID.
- A rebuild of the Loam app during development ends every running session.
- If Claude Code lets a background session keep its start folder and its session ID, this ADR is the one to revisit.
