One plot in the sidebar tree: its symbol, the name, and an attention mark at the trailing edge.

- The sidebar is a native sidebar list on the system glass (ticket 71). The list gives the row height, the indentation, and the disclosure arrows. Loam paints the selected row fill itself (ticket 86).
- The tree has three levels. The plot (`square.stack.3d.down.right`, name in semibold). Under it, the main checkout (`arrow.triangle.branch`) and each worktree (`arrow.triangle.pull`), named by the branch. Under each of those, its panes (`terminal`, the title that the terminal set, else `claude` or `shell`).
- A plot with no main repo holds its panes outside a worktree itself, with no main checkout row.
- The active plot's symbol is `moss`. The selected row is where you are: the focused pane, else the active plot.
- Muted rows (ticket 86): a row that is not selected shows its label and symbol in `ink-muted`. The selected row shows `ink` on a neutral fill (the ink at about 9%, radius 7), not `moss-wash`. The list draws no native selection. Each row paints its own fill and takes a click. Attention marks do not change.
- Rows are about 30 pt high (`minHeight` 26 pt plus the list padding).
- The active plot opens by itself, so by default only the active plot shows its panes. A plot that you open stays open. A closed main checkout or worktree counts its panes in a chip.
- The trailing slot of a plot shows a `loam-badge` with the count of panes that need you, or a `loam-dot--unread` ring when only Done, unread applies, or nothing. A pane row shows its own mark.
- A long name truncates with an ellipsis. Never wrap a plot name. A long branch truncates in the middle.
- Section labels are in sentence case, 12 pt, medium, `ink-faint`, with 10 pt of extra space above: "Plots", "No panes", "Archived". A `+` button at the right of "Plots" does what File > New Plot does. The "Archived" section is collapsed by default. Archived rows are `ink-faint` and show no dots.
- Order is the stored plot order. Drag a plot between rows to reorder it (ticket 98), as the Finder sidebar Favorites move:
  - A press on a plot row and a move of 4pt starts a drag. A shorter move is a click and selects the plot. A right click still opens the row menu.
  - The plot follows the pointer up and down its own section, "Plots" or "No panes", and stays inside it. An open plot moves with its whole tree. It sits on a lifted card: `horizon-b`, radius 7, inset 8pt like the selected fill, with a soft shadow.
  - The other plots part to open a gap where it will land, and the gap behind it closes: `duration-base`, `ease-settle`. A plot gives up its place when the edge of the dragged plot passes its midpoint, so a tall open plot lands where it shows.
  - On release the plot settles into the gap in `duration-base`. The sidebar shows the new order at once, and the ⌃1 to ⌃9 numbers follow it. Then `loam move` stores it. If `loam move` fails, the plot goes back and the error shows under the list.
  - Escape, or a release outside the sidebar, sends every row back in `duration-slow`.
  - Archived plots do not drag.
  - Reduce Motion: nothing slides. The dragged plot dims to 50% in place, a 2pt `moss` line marks the drop point, and the release moves the plot at once.

The consumer provides the name, whether it is active or archived, the attention counts, and the tree.

## Top of the sidebar (ticket 86)

- Search button: under the window buttons, full width, 32 pt high, radius 8. The fill is the ink at 5% with an ink hairline at 8%. It shows `magnifyingglass`, "Search" in `ink-faint`, and the keycaps command and K. A click opens the switcher, as the key does. It does not take text.
- Two fixed attention rows, 28 pt high, with `ink-muted` labels. "Needs you" has the amber dot and a pill count (`needs-you` text on `needs-you-wash`). "Done, unread" has the blue ring and a plain count in `ink-faint`.
- A click on an attention row focuses the next pane in that state, across plots, after the focused pane, and wraps round (`AttentionCycle` in LoamKit). With a count of 0 the row shows no count and does nothing.
- The old "Needs you" list of panes is gone. The attention row replaces it.
- The keycap is a 20 pt square, radius 5, the ink at 10%, 11.5 pt text in `ink-muted`.
