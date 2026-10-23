The New worktree sheet makes one worktree and starts a seeded session in it (ticket 115). It asks for a repo, a branch, a base, a goal and a link, and it checks the branch as you type. It is a card over the window, not a native sheet, so the keys of the window reach it. It replaces the one-field alert of earlier versions.

## Where it opens

- Start work… in the Link actions menu of a link row in the plot panel. It is the first row, over a divider. Only a Linear issue link and a GitHub issue link have it. A GitHub pull request link, a Linear project and a Linear document do not.
- ⌘Return on such a link in the quick switcher (see [Switcher](../Switcher/README.md)). The plot of the link becomes active first, so the sheet opens over that plot.
- New worktree… in the context menu of a plot row in the sidebar.
- The + button (New worktree…) in the header of the Worktrees section of the plot panel.
- Start work… opens the sheet with a link card and takes the fields from the link. The other two entries open it with empty fields and the Link field on None.
- The sheet opens for one plot. It reads the plot for its repos and links. Until they arrive, Start session is off.
- One overlay shows at a time. Opening the sheet closes the quick switcher, the actions menu, the PR popover and the Land sheet. The sheet sits over the Land sheet and under the quick switcher.
- The sheet does not open while a merge runs or while a worktree is made. The menu entries do nothing then, and ⌘Return in the switcher only closes the switcher.
- While a worktree is made, the sheet keeps the window (`sheetHoldsWindow`), because it cannot close. No other overlay opens then: ⌘P and ⌘⇧P (the quick switcher), ⌘J (the actions menu), ⌘⇧L, the PR popover and the Land sheet do nothing. A merge in the Land sheet keeps the window in the same way.

## The card

- 560pt wide, `horizon-a`, radius `radius-lg`, a hairline edge, and each layer of `shadow-switcher` (`loamFloating`), over a dim scrim: near black at 40% in Night, and the brown of the Day shadow at 28% in Day. It is the card of the [Land sheet](../LandSheet/README.md) (`sheetCard`). A click on the scrim closes the sheet.
- The scrim covers the title bar and the toolbar, and the toolbar items are off while the sheet shows, as in the Land sheet.
- It drops in 24pt from the top with `duration-slow` and `ease-settle`. Under Reduce Motion it fades only.
- From top to bottom: the title, the link card (only from a link), the fields, and "What the seed adds". Then come a callout, when something went wrong, and the footer.
- Title: "New worktree" in 15pt semibold.
- Link card: `horizon-b`, radius `radius-md`, a hairline edge. It shows the mark of the link kind and the label of the link (13pt medium, up to 2 lines). Under them is a note in 11.5pt `ink-muted`: "Loam does not copy the issue. The session reads it through its Linear connector." A GitHub issue says GitHub.
- Footer: a hairline, then the text "Loam makes the worktree and starts a seeded session in it." in 12pt `ink-muted`. Cancel and the primary button "Start session" follow. Both are native buttons at the large size, so they are capsules of one height. Cancel is the secondary style (`loamSecondaryButton`, a native bordered button), and Start session is the primary style (`loamPrimaryButton`).

## The fields

Each row has a label in `ink-muted` (84pt wide) and a control 28pt high. The rows are 12pt apart.

| Field | Control | What it does |
| --- | --- | --- |
| Repo | Popup with a folder mark and the folder name of the repo. The main repo has a "Main repo" tag in `ink-faint`. | Starts on the main repo, or on the first repo when none is main. A new repo sets Base back to the default. |
| Branch | Text field, mono 12.5pt, placeholder "Branch name". | Takes its text from the link until you type in it. The note under it comes from the check. |
| Base | Popup, mono 12.5pt. | The first entry is the default base, such as `origin/main`, and it means no base. Before the first answer, or when the repo has no default base, it reads "Default branch of origin". The other entries come from the check. |
| Goal | Text field, 13pt. | Takes its text from the link until you type in it. The note says "One line. You can leave it empty." |
| Link | Popup: None, each link of the plot with the mark of its kind, a divider, and "Paste a URL…". | Starts on None, or on the link of Start work…. |

- Choosing "Paste a URL…" shows a URL field under the popup: mono 12pt, placeholder "URL of a Linear issue or a GitHub issue".
- A popup has radius 6, a faint fill, a hairline edge, and an up and down mark at the right. A text field is a field box (`loamFieldBox`): `horizon-b`, radius `radius-sm` and an ink hairline edge, with no `edge` border. It looks like the Where it stands card of the plot panel.
- A note under a field is 11pt. A hint is `ink-muted`, a warning is `needs-you`, and a problem is `rust`.

### What the link fills in

- The Branch and the Goal take text from the link only while you have not typed in the field. A field that you empty takes its text from the link again. A new link or a new pasted URL fills both fields again.
- Branch: the issue key and the label, in lower case, with hyphens between the words. A Linear issue gives "eng-482-link-kinds-for-figma". GitHub issue 57 gives "57-fix-the-switcher-width". A Latin letter with a mark loses the mark. A name over 60 characters is cut at a hyphen.
- Goal: the label without its key, such as "Link kinds for Figma". It is empty when the label is only the key.
- A pasted URL has no label, so it gives the key as the branch and no goal.
- A link of the plot that is not an issue gives no branch and no goal. The worktree keeps the link.
- Under a branch that came from the link, the note says "From the issue key and the link label." For a pasted URL, it says "From the issue key."
- A goal over 20 words gets the warning "The goal has 24 words. The soft limit is 20 words." Start session stays on.
- A pasted URL has the hint "Loam saves this link with the worktree. It does not go into the plot's links."
- A URL that is not the URL of a Linear issue or a GitHub issue gets the note "Paste the URL of a Linear issue or a GitHub issue." in `rust`. Start session goes off.

### What the seed adds

- A disclosure under the fields, closed when the sheet opens. The label is 12pt medium `ink-faint`. The chevron turns 90 degrees when it opens, over `duration-base` with `ease-settle`.
- Open, it shows "Loam adds this line to the seed of the plot." Under it is the line, in mono 11.5pt, in a box on `horizon-b` with radius 8 and a hairline edge. You can select the line.
- The line is the `seed_line` of the check. The box says "The line shows when the branch name is good." while the name is empty or not good. It says the same from a change of the name, the repo or the base until the check for the new values is back, because the older line names another branch, repo or base.
- A change of the goal or the link keeps the line until the next answer.

## The branch check

- Loam runs `loam worktree new --dry-run` 250ms after the last change of a field. A newer change cancels an older check, so only the last change asks the core.
- An answer belongs to the name, the repo and the base that it was asked for. A change of one of them makes the answer old, and the branch is under check again. A change of the goal or the link does not make it old. Start session stays on, and the seed line gets its new text with the next answer.
- A name that starts with "-" is not sent to the core, because `loam` would read it as a flag. The sheet shows the problem at once.

| Branch | Note under the field | Base | Start session |
| --- | --- | --- | --- |
| Empty | None. | On | Off |
| Under check | None, or the hint from the link. | On | Off |
| New | None, or the hint from the link. | On | On |
| Exists | "A branch with this name exists. Loam uses it as it is." in `rust`. | Dimmed to 45% and off. Loam sends no base. | On |
| Not a good name | The message of the core as a sentence, in `rust`. | On | Off |
| Taken | "A worktree or a folder named `<folder>` exists already." in `rust`. | On | Off |
| Check failed | The message of the core as a sentence, in `rust`. | On | Off |

- The note for a branch that exists is `rust`, and Start session is still on. The branch is not an error: the note tells you what Loam does.
- Start session is also off while the plot loads, while the pasted URL is wrong, and while a worktree is made.

## Start

1. Start session runs `loam worktree new` with the plot, the repo, the name, the base, the goal and the link. The base is left out for a branch that exists. A goal that is only white space is left out.
2. The button shows a small spinner and "Starting…". The fields lock, and "What the seed adds" stays open or closed as it was. Cancel is off. Escape, Cancel and a click on the scrim do nothing, because the core cannot stop in the middle.
3. When it works, Loam reloads the worktrees, closes the sheet, and opens a seeded session in the new worktree.
4. When it fails, the sheet stays open. A callout shows the message of the core: a `rust-wash` box with a 6pt `rust` dot and 12.5pt text that you can select. It sits between the fields and the footer. A change of any field clears it.

- A Return that comes while the plot loads or a check runs waits for the answer. The button shows "Starting…" in the meantime. The start runs when the answer is back and allows it. A change of a field takes the Return back. A Return for an empty or wrong name does nothing, because its note is on the sheet.
- When the plot has no repo, or Loam cannot read the plot, one callout replaces the link card, the fields and the seed. It says "The plot has no repo. Add a repo first." or the message of the core. Start session is off and Cancel closes the sheet.

## Keys

- The sheet takes the keys when it opens, and the Branch field has them. From a link, Return starts a session. From the + button or the plot menu, the first key names the branch.
- The window gives the keys to the sheet a short time after it appears, so the sheet sets the focus on Branch up to 5 times, 30ms apart. The first try always sets Branch. A control that you chose in the meantime, with a click or a Tab, keeps the keys, and the later tries leave it.
- Return starts the session, also inside a text field. Escape or Cancel closes the sheet, and a click on the scrim closes it. While a worktree is made, none of the three closes it.
- While an input method composes text, Escape belongs to the input method and does not close the sheet.
- The keys go back to the focused pane when the sheet closes.

## After it starts

- The new worktree shows its issue key on the sidebar row when the key fits. It also shows the key on line 2 of its row in the Worktrees section ("ENG-482 · No changes"). The tooltip and the VoiceOver label of the sidebar row always have the key and the goal.
- The PR popover of a worktree with no PR has a Goal row that you can edit and a Link row. A goal that changed while you edited is not overwritten. See [PRPopover](../PRPopover/README.md).
- The Land sheet of a worktree that started from a plot link has a fourth box, "Remove ENG-482 from the plot's links". See [LandSheet](../LandSheet/README.md).
