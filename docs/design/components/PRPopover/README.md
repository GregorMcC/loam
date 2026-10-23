The PR popover shows the state of the PR of one worktree and the actions that go with it (ticket 109). It is a card over the window, not a native popover, so it can use `horizon-b` and `shadow-raised` and take keys from the window.

## Where it opens

- The chip of the action bar, the stage mark of a sidebar row, and a row of the Worktrees section open it below or above the control that was clicked.
- ⌘⇧L, a worktree in the switcher, and Show pull request in the ⌘J menu open it at the chip of the action bar. When the chip is the PR of another worktree, or there is no chip, it opens at the left end of the bar.
- The card follows the control that opened it when a resize of the window, a drag of a divider, or the sidebar or the plot panel moves the control. When the control goes, such as a row of a column that hides, the popover closes.
- The popover has a state of its own. It opens for one worktree. It closes when the focus moves to another pane, tab or space, and when its worktree leaves the list. It also closes when the quick switcher, the actions menu, the Land sheet or the New worktree sheet opens.
- One overlay shows at a time. The popover, the quick switcher and the actions menu close each other when they open. The [Land sheet](../LandSheet/README.md) and the [New worktree sheet](../NewWorktreeSheet/README.md) close the popover when they open.
- The popover does not open while a sheet shows or keeps the window (a merge, or a worktree that is made). The keys and menu items that open it are off then, and the scrim takes the clicks. It would take the keys from that sheet.

## The card

- 360pt wide, radius `radius-md`, `horizon-b`, a hairline edge, and each layer of `shadow-raised` (`loamFloating`), as the ⌘J menu has. It opens below the control when it fits, else above, else on the side with more room. It keeps 8pt from each window edge and 6pt from the control.
- The card is as tall as its content and at most as tall as the window less the two 8pt margins. The card picks its side again on each layout, so a card that gets taller (a refresh that adds failed checks, a notice or a button note) or a window that gets shorter moves it to the other side when it no longer fits. While the passed list is open, the card keeps the side it had (`PopoverMeasure`): the list makes the card taller, and the card grows away from the control and moves only as far as it needs to stay inside the window. The card is laid out in one pass (`PopoverLayout`), so a card that grows is never drawn at its new size and its old place.
- Header: the stage symbol and the stage in words, in the colour of the stage. At the trailing edge, "Updated 18:14" in `ink-faint`, the time of the last answer of GitHub. While the app asks GitHub about the worktree, this reads "Updating…". Each open asks once. An open while that ask runs joins it and starts no other. Refresh in the ⌘J menu waits for it and then asks again, so it shows a push made a moment ago.
- Title: "#142 Link labels from plot brief" in 14pt semibold, then "link-labels → main · 9 commits" in mono, `ink-muted`.
- Four rows between two hairlines: Checks, Review, Base, Conflicts. The words come from `StatusLine`, so the sidebar tooltip, the Worktrees section and the popover say the same. Only the failing words are `rust`.
- Blocked and In merge queue add one line under the rows. A repo with no GitHub remote, and a refresh that failed, add a line under the title.
- Failed checks: a list under the rows. Each row has the `rust` symbol, the check name in mono, how long it ran, and a Log link to the page of the check. Only failed checks are listed, 30pt per row.
- Passed checks (ticket 116): the last row of the list, "12 passed", has the `checkmark.circle` symbol and a `chevron.right`, in `ink-muted`, 30pt high, with `ink` at 5% under the pointer. It shows only when the PR is open and has failed checks and passed checks. With no failed check, the Checks row says "14 of 14 passed" and there is no list. The count is the length of `passed_checks`, and the Checks row says the same count (`StatusLine.passed`). A skipped or neutral check counts as passed, so it is in the list.
  - A click on the row opens the list under it and turns the chevron down. A second click closes it. The list is closed on each open of the popover, and it stays open through a refresh and a button.
  - Each passed check is a row like a failed one: `checkmark.circle` in `ink-muted`, the name in mono, how long it ran, and a Log link.
  - The list is as tall as its rows, and it scrolls inside the card when the card would be taller than the window allows (`PopoverLayout`). The rest of the card keeps its size.
  - The row takes no keys. Escape closes the popover with the list open or closed.
- A merged or closed PR has one State row and no list.
- A worktree with no PR has no header. It shows its branch in mono and "No pull request yet". A hairline stands above the rows Goal, Link, Base (mono) and Local. The buttons Open on GitHub (when the branch is pushed) and Copy branch name follow. See [The Goal and Link rows](#the-goal-and-link-rows).
  - Link shows only when the worktree has a link.
  - Base shows only when the worktree has a base. A worktree that started on a branch that existed has none.
  - A worktree whose folder is gone has no Goal, Link or Local row. The line under the branch is its status line, and not "No pull request yet".

## The Goal and Link rows

A worktree with no PR has these two rows above Base (ticket 115). A worktree with a PR has neither. Each row is 28pt high. Its label stands in an 84pt column, in `ink-faint`, as in the rows of the plot panel, and its text is 12.5pt.

### Goal

- The goal shows in `ink` on one line, and the end is cut when it is long. The tooltip holds the whole goal. A worktree with no goal shows "Add a goal" in `ink-faint`.
- The row shows for every worktree with no PR whose folder is there, also when the goal is empty.
- Under the pointer, the goal gets a fill of `ink` at 5% (`LoamColor.inkFill`) and a `pencil` mark in `ink-muted` at the trailing edge. A click on the goal starts the edit.
- The edit replaces the goal with a field: a field box (`loamFieldBox`) on `horizon-a`, 24pt high. The field has the keys, and it holds the goal as it is now. Return saves, and Escape cancels.
- A goal over 20 words gets the warning "The goal has 24 words. The soft limit is 20 words." in `needs-you`, under the field. The goal still saves.
- A note about a save takes the place of the warning, and it is `rust`. A change of the text takes the note away.
- A save runs `loam worktree edit --goal` as one change with Undo, written by the app. The text loses the white space at both ends, and an empty text clears the goal. The field is off while the save runs.
- The save expects the version of the goal that the edit opened with, so a goal that a session set meanwhile is never overwritten:
  - When the goal changed, nothing saves. The field shows the new goal in place of your text, with the note "The goal changed meanwhile. Loam shows the new goal." The next Return saves against the new version.
  - When Loam cannot read the new goal, your text stays. The note says "The goal changed meanwhile, but Loam could not read the new goal. Press Return to try again."
  - Any other failure shows the message of the core, and the edit stays open.
- The edit ends on a save that works and on Escape. It also ends when the popover closes or opens again, and when the worktree gets a PR, because the row then goes.

### Link

- The Link row shows the link that the worktree was made with. A mark of 12pt comes first, then the label, such as "ENG-482 Link kinds for Figma". The label is one line in `ink`.
- An issue shows the Linear mark or the GitHub mark. A claude.ai address shows the Claude mark. Any other link shows the `link` symbol.
- A click opens the link in the browser when the link is an https address. The popover stays open. Any other link only names itself, and a click does nothing. The tooltip is the address, else the label.

## Buttons

- The primary button is the full-width button of the stage, with Return as its key. The stage decides it: Land… at Ready to merge, and Send failures, Send review or Send conflicts to session at Checks failed, Changes requested and Conflicts. The three Send buttons are ticket 110. Land… closes the popover and opens the Land sheet (ticket 112, see [LandSheet](../LandSheet/README.md)).
- A Send button types a fix prompt into the session of the worktree, and you press Return (ticket 110, boards 2.1 to 2.3). The prompt names the `gh` command that shows the details, and never holds the text of a log or a comment. It is one line. The review and conflicts prompts start with "PR #139", because a line that starts with "#" can save the line as a memory in Claude Code. A check name loses the characters that show nothing (format, private use, unassigned and default ignorable code points, such as variation selectors) and stops at 80 code points. `SendPlan` in LoamKit decides what the button does:
  - The session pane is a seeded session of the worktree. Of two or more, it is the one focused last.
  - Loam types only when the session is idle and its input can hold none of your text. A key puts text in (of the ⌘ keys, only ⌘⌫ and ⌘⌦ count), and so do a paste, dictated text and a drop. The keys of a permission dialog or a question go to the dialog and do not count. The first Return, digit 1 to 9 or Escape answers the dialog, and the keys after it count again. That Escape counts too, but the Return or digit does not, and a later Return in the same dialog does not send the input. ⌃S stashes your draft, and Claude Code puts it back after your next prompt or `/clear`, so the input still holds your text then. A paste, dictated text and a drop count also in a dialog. The input is empty again when Claude Code takes the prompt that you sent with Return: a `UserPromptSubmit` that comes at most 3 seconds after your Return takes the text before that Return, and a key after the Return still counts. A turn that Claude Code starts by itself has no Return before it, so it leaves your draft in the input, as a Stop does. A new session (startup, resume or `/clear`) starts with an empty input, and a compact or a fork keeps it. The button then names the pane after its words, 12pt medium at 75% opacity, and the line under the buttons says "Loam types the prompt into the session. You press Return." The click focuses the pane, types the prompt with no Return, and shows a toast in the action bar. When Return in the popover ran the button, the terminal drops the repeats of the held Return, so the prompt waits for a new press. A second click finds the prompt in the input and does not type it again.
  - When Loam cannot type, the button is Copy prompt, and the line says why: the session is busy, has not started, has your text, or has another prompt from Loam. The click copies the prompt, and the popover says "Copied the prompt."
  - With no session in the worktree, the button is Start session with prompt. Loam starts a seeded session in the worktree and types the prompt after its SessionStart. When no SessionStart comes in 30 seconds, Loam types nothing, and a notice toast says "The session in native-panel did not start in 30 seconds. Loam did not type the prompt." When the session cannot take the prompt at its SessionStart, Loam types nothing, and a notice toast says why. When Loam opens no session, such as when the plot of the worktree is not in the list, a notice toast says so. The popover does not open, because the pane can still show the setup question, and Return would then run Copy prompt. A second click while the session starts copies the prompt.
- The smaller buttons are native bordered buttons at the large size of the primary button, so all the buttons of the card are capsules of one height. They stand two to a row under the primary button, in order. A button with no partner, such as a single button or the third of three, takes a row of its own at the full width (`PRPopoverContent.secondaryRows`). They show only when they can do something.
  - Re-run failed: when a failed check has a run. It runs `loam worktree rerun`.
  - Update branch: when the PR is behind its base and is not in the merge queue. It runs `loam worktree update`.
  - Open on GitHub: opens the PR, or the compare page of a pushed branch with no PR (`WorktreeStatus.githubPage`). The item of the worktree menu opens the same page. The popover stays open.
  - Copy branch name: for a worktree with no PR. The popover says "Copied the branch name."
- Re-run failed and Update branch run one at a time for a worktree. A spinner shows in the button that runs, also in a popover that closed and opened again on the worktree during the run. The popover then says what GitHub did, in one line under the buttons, and asks GitHub about the worktree again so the card shows the new state. An error shows in that line, not in the error bar of the window.
- A command goes on when the popover closes or shows another worktree. When it ends, the app still asks GitHub about the worktree again, and an error shows in the error bar of the window.

## Keys

- Escape or a click outside closes the popover. The keys go back to where they were: the field of the plot panel that had them, with its selection, else the focused pane.
- While an input method composes text, Escape belongs to the input method and does not close the popover.
- While you edit the goal, Escape ends the edit and keeps the popover. The next Escape closes it. Return in the goal field saves the goal and never runs the primary button. When the edit ends, the keys go back to the card.
- Opening or closing the popover does not move the keys of a refresh. A refresh of the PR data never takes the keys from a field.
