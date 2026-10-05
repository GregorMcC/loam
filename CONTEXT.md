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
A labelled pointer from a plot to an outside resource, such as a Notion page, a Linear issue, a vault folder, or a URL. It can carry a note that says why it matters. A link to a local folder or file is a **local link**; a session can read it like a repo. A local link inside an Obsidian vault is a **vault link**.
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
What a seeded session receives from its plot at start: the brief, the repos, and the links. A seed never holds page content.
_Avoid_: context, prompt, preload

**Seeded session**:
A Claude Code session that Loam started with a plot's seed.
_Avoid_: agent, plot session

**Pane**:
One terminal surface in the Loam app. A pane belongs to exactly one plot. It runs a seeded session or a shell. When its session ends, the pane stays until you close it.
_Avoid_: surface, split, window

**Needs you**:
The alert state of a pane whose session waits on your answer in the middle of a turn, such as a permission prompt or a question. It clears only when the session moves on.
_Avoid_: blocked, waiting, pending

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
