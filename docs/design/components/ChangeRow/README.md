One change from the change log, with who made it and an Undo.

- The first line says what changed, starting with the actor: "Claude set Where it stands", "You added the link Loam roadmap". The meta line gives the time and the source: seeded session, another Claude session, CLI, or app.
- Undo is a `loam-btn--quiet`. It runs `loam undo --json`. A clash (exit 11) opens the clash sheet with Cancel and "Undo and overwrite" (`loam-btn--danger`).
- In the app (ticket 87), the changes are a timeline in the plot panel under the heading "Changes". Each row has a 20pt round avatar on a thin vertical line (`rule`): the Claude mark for a session, `person` for you, `terminal` for the CLI. The first line is the actor in `ink`, medium, then the rest in `ink-muted` ("Claude set Where it stands"). The caption is the time and the source in `ink-faint` ("14:02 · seeded session"). A session that has a pane is a button that goes to the pane.
- In the app, Undo is a small text button at the right. It shows while the pointer or the keyboard focus is on the row. A disclosure chevron at the far right opens and closes the diff in the log. Under "New since you looked", the diff is always open.
- In the app, the undo clash is a callout at the top of the panel, in the banner style of the panel (`needs-you-wash`, radius 10, a dot, small pill buttons). It shows the later change with its diff, then what undo would write. "Undo and overwrite" is a native button with the destructive role, in `rust`.
- An undone change stays. It takes `is-undone`: its text dims and the action becomes "undone HH:MM".
- A change that arrives from the feed takes `is-new` and grows in with `ease-settle`.
- Plot creation has no Undo.
- The change log shows 10 changes to a page, newest first. With more than one page, a last row gives the range ("11 to 20 of 47") in `ink-muted` and chevron buttons for newer and older changes. A plot switch goes back to the newest page.

The consumer provides the change record from `loam changes --json`.
