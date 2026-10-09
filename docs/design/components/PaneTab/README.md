A tab in the pane area. A tab holds one pane or a split of panes, all in one plot.

- The tab bar is the top row of the terminal well (ticket 88). It is 40pt high on `bedrock`, with a hairline under it: the ink at 8% alpha, the same as the edge of the well.
- Each tab is a pill: 28pt high, radius 8, 11pt side padding, 4pt apart. The first pill starts 8pt from the edge of the well.
- A pill shows the pane symbol (13pt box), a 7pt gap, the label in 12.5pt medium text, and the attention mark after the label.
- The selected pill has the ink at 9% as a fill, a hairline edge, `ink` text and an `ink-muted` symbol. Other pills have `ink-muted` text and an `ink-faint` symbol, and take the ink at 5% as a fill on hover. There is no underline.
- On hover, a close `x` takes the place of the pane symbol (ticket 96). It shows only for the hovered tab, selected or not. The pill keeps its width and the attention mark stays at the trailing edge. The `x` is a 16pt square with the `xmark` symbol at 9pt in `ink-muted`. On its own hover it takes the ink at 5% as a fill (radius 4) and `ink` for the symbol. Its accessibility label is "Close tab" and its identifier is `tab-close-<number>`.
- A click on the `x` closes that tab and does not select it first. It follows the rule of ⌘W: a tab with a session that is mid-turn or needs you asks first.
- Drag to reorder (ticket 98), as Safari and Ghostty tabs move:
  - A press on a pill and a move of 4pt starts a drag. A shorter move is a click, and the release selects the tab. The `x` closes and never starts a drag.
  - The dragged pill follows the pointer along the bar and stays inside it. It draws above the others on a `bedrock` ground, with the hover look, a hairline edge and a soft shadow (black at 28%, 8pt blur, 2pt down).
  - The other pills slide aside to open its slot when the pointer passes their midpoint: `duration-base`, `ease-settle`.
  - On release the pill settles into its slot in `duration-base`, then the order changes. Escape, or a release outside the bar, sends every pill back in `duration-slow`.
  - Only within the tab bar of the active plot. The selected tab stays selected. The new order is the workspace order, so the saved window state and ⌘1 to ⌘9 follow it.
  - Reduce Motion: nothing slides. The dragged pill dims to 50% in place, a 2pt `moss` line marks the drop point, and the release moves the tab at once.
- A `+` icon button (28pt, radius 7) follows the last pill. It starts a new session, as the toolbar `+` and ⌘T do.
- One label per tab (ticket 71): the title of the focused pane, once. That is the title that the terminal set, else `claude` for a seeded session or `shell` for a shell. The symbol is the one of the focused pane: the Claude mark for a seeded session, `terminal` for a shell.
- The trailing slot repeats the pane's attention mark. In a split tab, show the strongest mark of its panes.
- A tab of one pane has no pane header. The tab label, the tab dot and the pane ring carry what the header would say. Each pane of a split tab has a header, so you can tell the panes apart. The header stands on `bedrock` with the same hairline under it as the tab bar. The focused pane's header has `ink` text, the others `ink-muted`.
- Every color mixes from the derived ink, so the tabs follow the terminal theme. In a translucent window the bar and the headers take `bedrock` at the window alpha.

The consumer provides the title, the symbol and the attention state.
