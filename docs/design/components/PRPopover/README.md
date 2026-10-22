The PR popover shows the state of the PR of one worktree and the actions that go with it (ticket 109). It is a card over the window, not a native popover, so it can use `horizon-b` and `shadow-raised` and take keys from the window.

## Where it opens

- The chip of the action bar, the stage mark of a sidebar row, and a row of the Worktrees section open it below or above the control that was clicked.
- ⌘⇧L, a worktree in the switcher, and Show pull request in the ⌘J menu open it at the chip of the action bar. When the chip is the PR of another worktree, or there is no chip, it opens at the left end of the bar.
- The card follows the control that opened it when a resize of the window, a drag of a divider, or the sidebar or the plot panel moves the control. When the control goes, such as a row of a column that hides, the popover closes.
- The popover has a state of its own. It opens for one worktree, and it closes when the focus moves to another pane, tab or space, when the quick switcher or the actions menu opens, and when its worktree leaves the list.
- One overlay shows at a time: the popover, the switcher and the actions menu close each other.

## The card

- 360pt wide, radius `radius-md`, `horizon-b`, a hairline edge, `shadow-raised`. It opens below the control when it fits, else above, else on the side with more room. It keeps 8pt from each window edge and 6pt from the control.
- Header: the stage symbol and the stage in words, in the colour of the stage. At the trailing edge, "Updated 18:14" in `ink-faint`, the time of the last answer of GitHub. While the app asks GitHub about the worktree, this reads "Updating…". Each open asks once. An open, or Refresh in the ⌘J menu, while that ask runs joins it and starts no other.
- Title: "#142 Link labels from plot brief" in 14pt semibold, then "link-labels → main · 9 commits" in mono, `ink-muted`.
- Four rows between two hairlines: Checks, Review, Base, Conflicts. The words come from `StatusLine`, so the sidebar tooltip, the Worktrees section and the popover say the same. Only the failing words are `rust`.
- Blocked and In merge queue add one line under the rows. A repo with no GitHub remote, and a refresh that failed, add a line under the title.
- Failed checks: a list under the rows. Each row has the `rust` symbol, the check name in mono, how long it ran, and a Log link to the page of the check. Only failed checks are listed.
- A merged or closed PR has one State row and no list.
- A worktree with no PR has no header. It shows its branch in mono, "No pull request yet", the Base (mono) and the Local state, and the buttons Open on GitHub (when the branch is pushed) and Copy branch name.

## Buttons

- The primary button is the full-width button of the stage, with Return as its key. The stage decides it: Land… at Ready to merge, and Send failures, Send review or Send conflicts to session at Checks failed, Changes requested and Conflicts. The slot and the rule exist, and no button shows until tickets 110 and 112 build them.
- The smaller buttons are 28pt high, radius 6. They show only when they can do something.
  - Re-run failed: when a failed check has a run. It runs `loam worktree rerun`.
  - Update branch: when the PR is behind its base and is not in the merge queue. It runs `loam worktree update`.
  - Open on GitHub: opens the PR, or the compare page of a pushed branch with no PR (`WorktreeStatus.githubPage`). The item of the worktree menu opens the same page. The popover stays open.
  - Copy branch name: for a worktree with no PR. The popover says "Copied the branch name."
- Re-run failed and Update branch run one at a time for a worktree. A spinner shows in the button that runs, also in a popover that closed and opened again on the worktree during the run. The popover then says what GitHub did, in one line under the buttons, and asks GitHub about the worktree again so the card shows the new state. An error shows in that line, not in the error bar of the window.
- A command goes on when the popover closes or shows another worktree. When it ends, the app still asks GitHub about the worktree again, and an error shows in the error bar of the window.

## Keys

- Escape or a click outside closes the popover. The keys go back to where they were: the field of the plot panel that had them, with its selection, else the focused pane.
- Opening or closing the popover does not move the keys of a refresh. A refresh of the PR data never takes the keys from a field.
