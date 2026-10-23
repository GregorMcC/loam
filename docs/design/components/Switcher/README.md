The quick switcher: one list of plots, panes, links, worktrees and actions across every plot that is not archived. Open it with ⌘P. ⌘⇧P opens it with `>` typed, so it lists actions only. It looks and works like Spotlight.

- It floats over the panes as a Liquid Glass panel (`glassEffect(.regular)`, radius 24, a soft shadow), up to 680px wide with a 24px margin each side of the pane area. This is the one glass surface over a pane. Nothing dims behind it. A click outside it closes it.
- It drops in 8px and grows from 98% over `duration-slow` with `ease-settle`. Under Reduce Motion it fades only.
- The search field is 56px tall: a 20pt `magnifyingglass` and 22pt text. The placeholder says that `>` lists actions only. The list sits under a `rule` hairline and grows to 420px.
- With no query it lists recent items: panes that need you, then plots and panes by use. While you type, it ranks by fuzzy match, then by recent use. Matched letters are `moss` and bold.
- Results sit in sections by kind (Panes, Plots, Links, Worktrees, Actions), with a caption heading. The section of the best result comes first, so Return still takes the best result.
- Each 36px row shows its icon (see Iconography: a Claude session shows the Claude mark, a GitHub link the GitHub mark), its name in 14pt, its plot in `ink-muted` when it is not a plot, a menu shortcut for an action, and an attention dot for a pane that needs you or is done, unread.
- Return makes a plot active, focuses a pane, opens a link with `loam open`, goes to a worktree and opens its PR popover, or runs an action. Arrow keys move the `moss-wash` selection (radius 10). Escape closes the switcher. While an input method composes text in the search field, Escape cancels the composed text and the switcher stays open.
- A link to a Linear issue or a GitHub issue has a second action, Start work… (ticket 115). ⌘Return runs it: the plot of the link becomes active, and the [New worktree sheet](../NewWorktreeSheet/README.md) opens with the link. On a result with no second action, ⌘Return does nothing.

The consumer provides the items, their icons, and their recent-use order.

## Preview and footer (ticket 90)

- When the pane area is at least 768pt wide, the panel widens to 860pt at most and splits into two columns by a `rule` hairline: the result list (400pt) and a preview of the selected result. With less room there is no preview, and the switcher stays one column of 680pt at most. The list height is 420pt, or less in a short window.
- A preview has a 34pt tile with the item's icon in `moss`, the name (18pt, semibold), and a caption in `ink-muted`. Metadata rows are 34pt high with a `rule` hairline under each. The label is `ink-faint` and the value is `ink`.
- Plot: caption "Plot · 3 panes · 4 links", then "Where it stands" and its text. Rows: Main repo (name and a branch chip), Panes, Needs you, Done, unread (each with its mark and the pane name), Last change ("You · CLI: Edited Where it stands, 14:02"), and Repos as tag pills. A row with no data is left out.
- Pane: caption "Pane · Shell" or "Pane · Claude session". Rows: Plot, Checkout (worktree name or repo name, with the branch chip), State, Folder (mono, with `~` for home). A saved pane that has not resumed says "Not resumed".
- Worktree: caption "Worktree · Ready to merge" (the stage). Rows: Plot, Pull request ("#22 Link labels"), Status (the status line of the stage), Folder (mono). Only a worktree with a PR and a folder is in the list, and it shows after you type, as a link does.
- Link: caption is the kind ("Local link", "GitHub link"). Rows: Target (mono for a file) and Plot.
- Action: caption "Action". One row, Shortcut, as keycaps. It is left out when the action has no key.
- The footer is 44pt high with a `rule` hairline above. It shows the icon of the selected result on the left. On the right it shows the primary action ("Open plot", "Go to pane", "Open link", "Show pull request", "Run") and a ↵ keycap. A click on it does what Return does. A result with a second action shows it left of the primary action, as "Start work…" and a ⌘↵ keycap. A click on it does what ⌘Return does.
- A row is 40pt high with radius 9. The selected row has a neutral fill (the ink at 9%) and no `moss-wash`. Matched letters stay `moss`. After the title come the attention mark of a pane and the subtitle in 13pt `ink-muted` (a plot's pane count, else the plot name). The kind sits on the right in `ink-faint` ("Plot", "Pane", "Local link"). An action shows its shortcut as keycaps instead. Section headings are 12pt, medium, `ink-faint`.
- Keycaps: 20pt squares, radius 5, a fill of the ink at 10%, 11.5pt text in `ink-muted`.
- The content comes from `SwitcherPreview` in LoamKit, a pure function of the item and the model data. The view renders one snapshot of the results, so a stale row index cannot crash it.
