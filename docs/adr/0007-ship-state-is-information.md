# Ship state is information

A worktree can have a pull request on GitHub, with checks and a review. Loam shows this ship state as one stage per worktree, from Not pushed to Merged, in the sidebar, the action bar, the pane header and the plot panel. A failed check can look like a third attention signal, next to Needs you and Done, unread. It is not one. Ship state is information that you look at when you choose to. Only a session that waits on you raises Needs you.

We chose this because checks fail often and most failures can wait. An alert for each one would teach you to ignore the alert states, and then Needs you would stop working. We did not choose a Dock badge or a banner for a failed check for the same reason.

Loam reads and writes GitHub only through the `gh` CLI, and only in the Loam core, so the app, a seeded session and a plain terminal see the same state (ADR 0002, ADR 0004). Loam holds no GitHub credentials. To help you fix a worktree, the app types a prompt into the worktree's session and never presses Return. The prompt names the `gh` command, and the session reads the logs and the comments itself, as it reads a link (ADR 0001). In a plain terminal, you run the same `gh` command.

## Consequences

- The core decides the stage, and the app only shows it. The stages, where the first one that applies wins: Merged, Closed, In merge queue, Conflicts, Changes requested, Checks failed, Approval needed, Behind base, Checks running, Waiting for review, Draft, Ready to merge, "Pushed, no PR", Not pushed.
- No stage raises Needs you, a banner, a Dock badge or a halo. The Ready to merge row in the sidebar has the shape of an attention row, but it has no state hue.
- Only Conflicts and Checks failed take `rust`. Every other stage is `ink`, `ink-muted` or `ink-faint`. No stage takes a new hue.
- Without `gh`, or with `gh` signed out, Loam shows local state only and says how to fix it.
- Ship state covers worktrees only. A pull request from the main checkout does not show.
- A merge is an action on GitHub, not an edit to a plot, so it writes no change and it cannot be undone. The design rule that every change is reversible covers edits to a plot. The Where it stands change that follows a merge is an edit, and it can be undone.
