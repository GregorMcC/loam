# Loam

Loam gives each area of work a home that every Claude Code session it starts can see. It exists so that a new session knows the key documents and the purpose of the work from its first message.

## Language

### Plots

**Plot**:
A named area of work that Loam keeps, made of a brief, links, and zero or more repos. A plot can be any work area, with or without code.
_Avoid_: context, project, workspace, area

**Archived plot**:
A plot that you have finished with but kept. It leaves the sidebar and the switcher, and its sessions cannot start until you unarchive it. Deleting a plot is permanent, and only an archived plot can be deleted.
_Avoid_: closed plot, done plot, hidden plot

**Brief**:
The short written description of a plot, in three parts: What (what the work is), Why (why it matters), and Where it stands. What and Why rarely change. Where it stands moves with the work.
_Avoid_: summary, description, notes

**Link**:
A labelled pointer from a plot to an outside resource, such as a Notion page, a Linear issue, a vault folder, or a URL. It can carry a note that says why it matters. A link to a local folder or file is a **local link**; a session can read it like a repo. A local link inside an Obsidian vault is a **vault link**. A link that a session added or last changed is **unchecked** until a person changes it: its note is data, and a local one is not an added folder.
_Avoid_: bookmark, reference, resource

**Repo**:
A local git checkout that a plot holds, with an optional note that says what it does in the plot. A repo can belong to many plots.
_Avoid_: project, codebase, checkout

**Main repo**:
The one repo of a plot where a seeded session starts unless you pick another. A plot with repos has exactly one main repo.
_Avoid_: primary repo, default repo

**Worktree**:
A separate git checkout of one repo of a plot, on its own branch, that Loam made for that plot. It outlives the panes that use it, and several panes can share it.
_Avoid_: task, workspace, branch

**Pull request**:
The GitHub pull request whose head is the branch of a worktree. Use the short form "PR" only where space is short, such as a chip or a status line.
_Avoid_: merge request

**Ship state**:
How far a worktree is from merged: its pull request, the checks, and the review. Loam shows it as one stage. It is information, not an alert state.
_Avoid_: PR status, CI status

**Stage**:
The one step of ship state that Loam shows for a worktree, from Not pushed to Merged. The core checks the stages in a fixed order, and the first one that applies wins (ADR 0007 lists them).
_Avoid_: status, phase

**Goal**:
One line that says what a worktree is for. The seed lists it, so a session in that worktree knows its task.
_Avoid_: task, title

**Link key**:
The short ID of the issue that the link of a worktree points at. For Linear it is the issue ID, such as ENG-482. For GitHub it is # and the number, such as #57, when the issue is in the repo of origin. Else it is owner/repo#57, because GitHub reads #57 as an issue of the PR's repo. A link that is not an issue has no key. A PR body puts "Fixes" and the key, so the merge closes the issue.
_Avoid_: issue number, ticket ID

**Land**:
To merge the pull request of a worktree and tidy up after it: remove the worktree, delete its branch, and move Where it stands on.
_Avoid_: finish, complete

**Plot folder**:
The folder that Loam keeps for each plot, outside every repo. It holds the plot's seed. A plot with no repos starts its seeded sessions there. Loam owns only the seed; other files in the folder are yours.
_Avoid_: plot directory, workspace

**Change**:
One edit to a plot by one actor, made of one or more changed fields. A change is the unit of undo.
_Avoid_: commit, edit, revision

**Change log**:
The record of every change to a plot, with who made it (you, a seeded session, or another Claude session) and when. Undo adds a change; it never removes one.
_Avoid_: history, audit trail

### Sessions

**Seed**:
What a seeded session receives from its plot at start: the brief, the repos, the worktrees with their goals, and the links. A seed never holds page content.
_Avoid_: context, prompt, preload

**Seeded session**:
A Claude Code session that Loam started with a plot's seed.
_Avoid_: agent, plot session

**Pane**:
One terminal surface in the Loam app. A pane belongs to exactly one plot, or to Home. It runs a seeded session, a Home session, or a shell. When its session ends, the pane stays until you close it.
_Avoid_: surface, split, window

**Home**:
The space above the plots in the sidebar for tabs that belong to no plot. Its panes start in your home folder. Home is not a plot: the core does not store it, and it has no brief, repos, or worktrees.
_Avoid_: scratch plot, default plot, unplotted

**Home session**:
A Claude Code session that Loam started in Home. It gets no seed and belongs to no plot, but the pane still sees its alert states.

**Needs you**:
The alert state of a pane whose session waits on your answer in the middle of a turn, such as a permission prompt or a question. It clears only when the session moves on.
_Avoid_: blocked, waiting, pending (Blocked is a stage: GitHub blocks the merge)

**Done, unread**:
The alert state of a pane whose session finished a turn that you have not seen. It clears when you look at the pane.
_Avoid_: idle, finished, complete

### Parts of Loam

**Loam core**:
The part of Loam that holds plots and starts seeded sessions. It works in any terminal, through the `loam` CLI and the MCP server.
_Avoid_: backend, daemon, engine

**Store**:
Where the Loam core keeps plots, their order, the change log, and the records of the sessions it started.
_Avoid_: database, backend

**Loam app**:
The macOS terminal app, built on libghostty. It is one front end to the Loam core.
_Avoid_: client, GUI, terminal
