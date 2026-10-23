The Land sheet lands one worktree: it shows what GitHub checks, merges the PR, removes the worktree, and moves Where it stands on (ticket 112). A merge on GitHub cannot be undone, so the sheet shows each check before you press Merge. It is a card over the window, not a native sheet, so the keys of the window reach it.

## Where it opens

- Land… in the PR popover (the primary button at Ready to merge), the Land… pill on a ready row of the Worktrees section, Land… in the Worktree actions menu (hover and context menus of a row), and Land… in the ⌘J menu. Each one shows only at Ready to merge.
- The sheet reads the PR again when it opens, so it can show a plan that is not the plan of the row. A row that was ready can show a failed check in the sheet.
- The sheet has a state of its own. It opens for one worktree. It closes when the PR popover opens, and when its worktree leaves the list. A merge that runs keeps it open until the merge ends. While the sheet shows or a merge runs, ⌘P, ⌘J, ⌘⇧L, Show Pull Request and the other commands that change the window do nothing (see Keys), because they would change the window under the sheet. Quit waits for the merge to end. A merge that fails cancels the quit, and the sheet shows the message of GitHub. Any other end goes on as a quit with no merge (the question when a session is mid-turn, and the close of the panes).
- One overlay shows at a time. When the sheet opens, it closes the PR popover, the quick switcher, the actions menu and the [New worktree sheet](../NewWorktreeSheet/README.md). While the sheet shows, the keys and menu items that open them are off (see Keys).

## The card

- 560pt wide, `horizon-a`, radius `radius-lg`, a hairline edge, and each layer of `shadow-switcher` (`loamFloating`), over a dim scrim: near black at 40% in Night, so the shadow still shows, and the brown of the Day shadow at 28% in Day. A click on the scrim closes the sheet. The New worktree sheet has the same card (`sheetCard`).
- The scrim covers the whole window, the title bar and the toolbar too, as the dim of a native macOS sheet does (ticket 126). The window buttons stay clear. A drag on the title bar moves the window, and a click there does nothing, as under a native sheet. While a sheet shows, the toolbar items are off: the sidebar button, "N elsewhere need you", New session and Plot panel take no click.
- It drops in from the toolbar row with `duration-slow` and `ease-settle`. Under Reduce Motion it fades only.
- Title: "Land #142 Link labels from plot brief" in 15pt semibold. Under it, in mono: "link-labels → main · 9 commits". While the plan loads, the title and the line come from the row of the worktree, and the checklist shows a spinner.
- The checklist "Before you merge" has one 30pt row for each check of `loam worktree land --dry-run`: a symbol, words, and a value at the trailing edge. `LandSheetContent` says what each row shows.
  - Checks: "Checks pass 14 of 14", "No checks", "Checks running 3 of 5 done", "Checks fail 2 of 14", "Checks wait for approval 2 waiting".
  - Review: "Review approved 1 approval", "Review needed", "Changes requested 3 comments", "No review required".
  - Base: "Up to date with main 0 behind", or "3 behind main" with an Update branch button. The note says "Does not block the merge". A base branch that needs the PR up to date makes the row block, and the note says "GitHub needs it up to date".
  - Conflicts: "No conflicts", "Checking for conflicts", "Conflicts with main".
  - GitHub: a row only when GitHub does not let the PR merge: "Draft pull request", "GitHub blocks the merge", "GitHub is checking the merge". The first two have an Open on GitHub button.
  - Worktree: "Worktree saved and pushed 0 changed · 0 not pushed", or "Worktree has local work" with a hint such as "Commit or push 2 files". When git cannot read the worktree, the row blocks with "Loam could not read the worktree" and the hint "Check the worktree in a terminal".
- A row that blocks takes the `rust` symbol, and its trailing edge says what to do. Failed checks, requested changes and conflicts get a button that sends a fix prompt to the session (ticket 110, see [PRPopover](../PRPopover/README.md)), when the stage of the worktree gives that very prompt. Else the row has a hint in `rust`. The label of the row for VoiceOver ends with "blocks the merge".
- Merge method: a segmented control with only the methods that the repo allows (Merge commit, Squash, Rebase). It starts on the default of the repo, with the caption "From the repo setting". Another choice changes the caption to "Not the repo setting". A merge queue has no control, because the queue merges with its own method.
- After the merge: three boxes, and a fourth box for a worktree that started from a link of the plot. All are on by default.
  - "Remove the worktree link-labels". With open panes it reads "Close its pane and remove the worktree" or "Close its 2 panes and remove the worktree". Off passes `--keep-worktree`.
  - "Delete the branch on GitHub". Off passes `--keep-remote-branch`.
  - "Move Where it stands on". Under it, a box with the Where it stands text: "Merged #142 Link labels from plot brief." before the current text. The box selects that sentence when it takes the keys, so one key replaces it. Return adds a line, and a held Return adds lines. ⌘Return merges. The caption is "Loam saves this as a change. You can undo it." The box looks like the Where it stands card of the plot panel: `horizon-b`, `radius-md` and a hairline (`loamFieldBox`). It has no `edge` border.
  - "Remove ENG-482 from the plot's links" (ticket 115). It is the last box, under the Where it stands box when that shows. The name is the issue key. A link with no key uses its label.
    - It shows only for a worktree that started from a link of the plot, while that link is still in the plot. A worktree that started from a pasted URL has no such link in the plot, so it has no box.
    - It shows only for a merge now. A merge that waits (`--auto` or a queue) has no box, and a PR that is merged already has no boxes at all.
    - It does not depend on the other boxes. The link goes when the merge works, also when the third box is off.
    - The box is on again each time the sheet opens.
- Footer: "You cannot undo a merge." in `ink-muted`, then Cancel and the primary button. Both are native buttons at the large size, so they are capsules of one height (`loamSecondaryButton`, `loamPrimaryButton`).

## States

| Plan | Primary button | Footer |
| --- | --- | --- |
| Every check passes | Merge #142 (Return) | You cannot undo a merge. |
| A check blocks | Merge #142, off | Fix the item in rust before you merge. Or: Fix the 2 items in rust before you merge. |
| The plan is not ready and no row blocks | Merge #142, off | Loam cannot merge this PR yet. Open the PR on GitHub to see why. |
| Checks running or waiting | Merge when ready (`--auto`) | GitHub merges #142 when its checks pass. Loam tidies up after the merge. |
| A merge queue | Add to merge queue | The queue merges #142 after its checks pass on main. |
| Already merged on GitHub | Off | #142 is merged on GitHub already. |

- Merge is off whenever the plan says that a check blocks, whatever you press: the button, Return and ⌘Return all do nothing. The model checks this too (`LandSheetContent.canMerge`), so a stale click cannot start a merge. The count in the footer is the count of rows in rust. A plan that is not ready for a reason that has no row gets the second footer text.
- Behind base does not block unless the base branch needs the PR up to date. The Update branch button runs `loam worktree update` and reads the plan again.
- For a merge that waits (`--auto` or a queue), Loam does not close any pane and does not save Where it stands. The third box is off and cannot be turned on. The fourth box does not show. A note under "After the merge" says "Loam does this when GitHub has merged the pull request."
  - The land records the first two boxes. When a refresh finds that GitHub merged the PR (ticket 113), Loam finishes the land as the boxes said. It deletes the branch on GitHub, closes the panes of the worktree, and removes the worktree. A box that was off skips its step.
  - Loam removes the worktree with no question only when that is safe. Else it asks in a callout at the top of the plot panel. A toast says what happened. See [After a merge on GitHub](../../../../README.md#after-a-merge-on-github).
  - Loam does not save Where it stands or remove the plot link at that time.

## Merge

1. With a merge now and the first box on, the panes of the worktree close. A pane in a turn asks first, through the close prompt ("Close its panes and merge?"). Cancel there cancels the land. The app writes the open panes to its state file before the next step, because the core refuses to remove a worktree that has an open pane.
2. `loam worktree land` runs with the method and the flags of the boxes, and with `--head` and the commit that the plan showed. When the PR has another head by then, the core stops with exit code 16 and a message such as "link-labels is not ready to land: PR #22 has new commits since you looked at it. Look again before you merge". Nothing merges, and the sheet reads the plan again. The button shows a spinner and "Merging…", the checklist locks, and Cancel is off.
3. When `land` fails, a `rust` callout inside the sheet shows the message of GitHub or of the core, and the sheet stays open. Each box keeps its value, so a second try needs one click. A check that blocks now, or a new commit on the PR (exit code 16), also makes the sheet read the plan again. Until the new plan is back, the sheet is locked like a sheet that loads, so Merge cannot run on the old plan. When the worktree has left the list by then, the sheet closes.
4. With the third box on, the app saves the text as Where it stands: one change with Undo, written by the app. It expects the version of Where it stands that the sheet read. When the plot changed meanwhile, Loam does not save the text, and the toast says so.
5. With the fourth box on, the app removes the plot link that the work started from. It is one change with Undo, written by the app, as in the panel. This step does not depend on the third box. It expects the version of the link that the sheet read. When the link changed in the plot meanwhile, Loam does not remove it. Any other failure leaves the link too. The toast says why, as a notice, and the sheet still closes.
6. The sheet closes, and the toast says "Merged #142. Removed the worktree link-labels." With the fourth box on, the toast ends with "Removed ENG-482 from the plot's links." A worktree that you kept shows the Merged stage in the Worktrees section, faded, with a Remove… pill. Loam does not ask about it again.

A merge writes no change-log row. The toast records it. The Where it stands change and the link removal are changes of their own.

## Keys

- Return merges, Escape or Cancel closes, and a click on the scrim closes. A merge that runs ignores all three. While an input method composes text in the box, Escape cancels the composed text and does not close the sheet.
- Only a first press of Return merges. A held Return does not repeat the merge. A Return that the box takes never merges: the box adds a line, or commits text that an input method composes. The sheet asks the window whether an editable text view has the keys (a selection in the error callout does not stop Return), and not only the focus of SwiftUI, which can be a short time behind the window. A held Return adds a line for each repeat, and it does not select the text.
- The sheet takes the keys when it opens. The keys go back to the focused pane when it closes.
- While the sheet shows or a merge runs, each menu item that changes the window is off in the menu bar, and its key does nothing (ticket 128). This covers ⌘T, ⌘I, ⌘B, ⌘L, ⌘P and ⌘J, and the tab, split, plot and space items. It is the rule of a native macOS sheet. Settings, Open and Reload Ghostty Config, and Quit stay on. Escape, Return, Tab and the text keys of a field (⌘A, ⌘C, ⌘V, ⌘X and ⌘Z) work as before. The toolbar items follow the same rule (ticket 126). A native sheet on the window does the same: the close question, the Ghostty config errors and the plot name dialog.

## The Worktrees section

- A ready row has a Land… pill before the menu button, in the pill style of the panel and not in `moss`.
- A merged row shows its branch, its number, its status line and its mark in `ink-faint`, with a Remove… pill in `ink` that asks the same question as Remove in the actions menu.
- A row that a land removes leaves with the row animation.
