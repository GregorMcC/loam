An 8px mark that says whether a pane or plot needs you. It is the only place the two attention hues appear.

- `loam-dot--needs`: a filled `needs-you` circle. A session waits on your answer mid-turn (a permission prompt or a question). Add `is-arriving` when the state starts: a ring grows out of the dot three times (`duration-halo`), then stops.
- `loam-dot--unread`: a hollow `done-unread` ring, 1.5px. A session finished a turn that you have not looked at.
- `loam-dot--active`: `moss`. The plot you are in.
- `loam-dot--idle`: `rule`. Any other plot.
- `loam-badge`: the count of panes that need you, on a sidebar row. Show it only for Needs you, never for Done, unread.

The consumer provides the state. Needs you clears only when the session moves on. Done, unread clears when you look at the pane. Never show both on one pane: Needs you wins.

Do not use the dot for running, idle or error. A running session has no mark.
