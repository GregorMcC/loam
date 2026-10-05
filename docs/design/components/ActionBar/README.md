The action bar is the 40pt strip at the bottom of the window (ticket 89). It sits under the terminal well and ends where the well ends. The plot panel runs past it to the bottom of the window, so the bar gets narrower when the panel opens. The actions menu opens from it.

## The bar

- The bar stands on the frame, the same as the margin of the well. It has no ground of its own and no top rule. The bottom edge of the well separates the bar from the well.
- Left side, in 12.5pt text:
  - the plot symbol in `moss` and the plot name in `ink`
  - a `/` in `ink-faint`
  - the label of the focused pane in `ink-muted`, the same label as its tab
  - the toast: a small `moss` check and the newest change of the active plot in `ink-faint`, for example "Claude set Where it stands"
- The toast shows for 6 seconds after a change, then fades. A change that was in the log when the app started does not show. The toast hides when the bar is too narrow for it.
- Right side: "New session" with its keycaps, a 16pt vertical rule (the ink at 13%), then "Actions" with its keycaps.
- The two buttons are text buttons: 28pt high, radius 7, `ink` text. They take the ink at 9% as a fill on hover. Actions keeps that fill while its menu is open.
- Keycaps are 20pt, radius 5, the ink at 10%, with `ink-muted` text.

## The actions menu

- ⌘J or a click on Actions opens the menu. ⌘J, Escape, or a click outside the menu closes it.
- The menu is a card above the Actions button: 340pt wide, radius 12, on `horizon-b`, with a hairline edge and `shadow-raised`. It sits 10pt from the right end of the bar and 6pt above it.
- The menu has two sections. The heading of each section is in `ink-faint`.
  - The focused pane, with its label as the heading: New session, Split right, Split down, Close pane.
  - The active plot, with its name as the heading: Edit brief, Add link, Add repo, Archive plot.
- Each row is 34pt high. It has a symbol in `ink-muted`, the label in `ink`, and the keycaps of the command on the right. The selected row has the ink at 9% as a fill, radius 8.
- A search field is at the bottom, under a hairline. It has the keys when the menu opens. Each word of the query must be in the label of a row. A section with no rows left does not show.
- The first row is selected. The up and down arrows move the selection. Return runs the selected row, and a click runs the row under the pointer. The menu closes and the pane gets the keys again.

## One source of truth

- Each row is a command of the menu bar (`AppCommand`). The keycaps come from the key of that menu item, so they are always the real keys, including a Ghostty binding.
- A command whose menu item is disabled is not in the menu. The menu bar and the menu use the same rule, `ActionMenu.isAvailable`: pane commands need a focused pane, and plot commands need an active plot.
- `ActionMenu` and `ActionMenuModel` in LoamKit hold the list, the filter and the selection. `ActionBarModel` holds the plot name, the pane label and the toast.

Every color mixes from the derived ink or comes from `ChromePalette`, so the bar and the menu follow the terminal theme.
