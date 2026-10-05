A tab in the pane area. A tab holds one pane or a split of panes, all in one plot.

- The tab bar is the top row of the terminal well (ticket 88). It is 40pt high on `bedrock`, with a hairline under it: the ink at 8% alpha, the same as the edge of the well.
- Each tab is a pill: 28pt high, radius 8, 11pt side padding, 4pt apart. The first pill starts 8pt from the edge of the well.
- A pill shows the pane symbol (13pt box), a 7pt gap, the label in 12.5pt medium text, and the attention mark after the label.
- The selected pill has the ink at 9% as a fill, a hairline edge, `ink` text and an `ink-muted` symbol. Other pills have `ink-muted` text and an `ink-faint` symbol, and take the ink at 5% as a fill on hover. There is no underline.
- A `+` icon button (28pt, radius 7) follows the last pill. It starts a new session, as the toolbar `+` and ⌘T do.
- One label per tab (ticket 71): the title of the focused pane, once. That is the title that the terminal set, else `claude` for a seeded session or `shell` for a shell. The symbol is the one of the focused pane: the Claude mark for a seeded session, `terminal` for a shell.
- The trailing slot repeats the pane's attention mark. In a split tab, show the strongest mark of its panes.
- A tab of one pane has no pane header. The tab label, the tab dot and the pane ring carry what the header would say. Each pane of a split tab has a header, so you can tell the panes apart. The header stands on `bedrock` with the same hairline under it as the tab bar. The focused pane's header has `ink` text, the others `ink-muted`.
- Every color mixes from the derived ink, so the tabs follow the terminal theme. In a translucent window the bar and the headers take `bedrock` at the window alpha.

The consumer provides the title, the symbol and the attention state.
