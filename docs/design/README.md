# Loam design system

The source of truth for how the Loam app looks and moves.

- Published system (tokens, type, components with live previews): https://claude.ai/artifact/GfPp3ZsjsqH7H88nP3g6w5
- Field study (a live, animated Loam window and the reasons behind each choice): https://claude.ai/artifact/GRvyHKGC7mt8ZipnLQbs2p
- In this folder: `tokens.json` (every token, Night and Day), `components/` (`bundle.css` plus a guideline and a preview per component), and `field-study.html` (the field study, opens in a browser).

The previews read the CSS custom properties that the published system compiles from `tokens.json` (`--bedrock`, `--space-2`, `--font-ui`, and so on).

---

Loam is a macOS terminal for work that Claude Code does with you. The interface is a **soil profile**: the deeper a surface sits, the closer it is to the work. Chrome is the top layer, the plot panel sits under it, and the terminal is bedrock. Nothing on screen competes with the terminal except the two signals that need you.

Build every surface from these tokens. Prefer native AppKit and SF Symbols, and use this system for what the platform does not give you: the palette, the attention states, the panel, and the switcher.

## Principles

1. **The terminal is the content.** Chrome stays quiet so the panes can be loud. Only `bedrock` holds terminal text, and no chrome element is darker (Night) or lighter (Day) than it. The chrome takes its surfaces and its ink from the terminal theme, so the frame and the panes read as one palette. The state hues stay fixed.
2. **Two signals, never more.** *Needs you* and *Done, unread* are the only attention states. They differ in hue (`needs-you` amber, `done-unread` blue) and in shape: a filled dot against a hollow ring. Do not add a third color for "running", "idle" or "error". A running session shows no badge.
3. **Every change is reversible, so show it.** Edits by Claude appear as change rows with an Undo. An undone change stays in the list and says "undone HH:MM". Never hide a change.
4. **Plots are places, not files.** A plot has a name and a brief, not a path. Show repos and links as things the plot holds, under the plot.

## Content fundamentals

Write in **Simplified Technical English**: short sentences, active voice, one instruction per sentence, no em dashes. Speak to the person as "you". Loam never says "I" in the UI. Claude's words appear only where Claude wrote them (the brief, a change).

Use the product's own nouns exactly, and never their synonyms:

| Say | Never say |
| :- | :- |
| plot | project, workspace, context |
| brief (What, Why, Where it stands) | summary, description |
| link, local link, vault link | bookmark, resource |
| main repo | primary repo |
| seeded session | agent, plot session |
| pane | split, surface |
| Needs you | blocked, waiting |
| Done, unread | idle, finished |
| archive, unarchive, delete | close, hide |

Real copy, as it appears in the app:

- Button: **New plot**, **Start session**, **Undo**, **Undo and overwrite**, **Archive plot**, **Delete plot**.
- Banner: "Session ended. Press Return to start a new session in this plot."
- Change row: "Claude set Where it stands" · "14:02 · seeded session".
- Undo clash: "A later change edited the same field. Undo writes the old value over it."
- Missing path: "This folder is gone. Edit the link or remove it."
- First run: "Claude will ask to trust this folder, choose Yes."

Casing: sentence case everywhere ("Start session", not "Start Session"). The state names *Needs you* and *Done, unread* keep their capital first letter, as names. No emoji in the UI.

## Visual foundations

### Color

With no Ghostty theme, the neutrals are warm, soil-brown greys in the 10YR family. Never use a neutral grey.

With a Ghostty theme, the chrome follows the terminal background (`ChromePalette` in `LoamKit`):

- `bedrock` is the theme background. The horizons, `rule` and `frame` step from it in OKLCH, with its hue. Night steps lighter and Day steps darker. Each horizon stays on its side of `bedrock` for every background.
- `ink`, `ink-muted` and `ink-faint` are neutral with a faint tint of the theme hue (chroma 0.012 at most). A grey theme gives a grey ink.
- Small text reaches 4.5:1 on `bedrock` and on each horizon. A text color that falls short moves in lightness only, as far as the ratio needs. `ink-faint` reaches 3:1.
- `moss`, `needs-you`, `done-unread` and `rust` keep their hue and chroma. They move in lightness only, and only where 4.5:1 needs it.
- The washes, `edge` and `focus` do not change.
- The window follows `background-opacity` and `background-blur`, as Ghostty does. At 1 the frame and the panes are solid.

- **Surfaces by depth.** `bedrock` for terminal panes. `frame` for the ground behind the glass sidebar: `bedrock` in Night, `horizon-o` in Day, so the edge of the glass shows. The chrome ground (`horizon-a` in Night, `horizon-o` in Day) for the toolbar row, the plot panel, the action bar and the margin of the well. `bedrock` for the tab bar and the pane header, inside the well. `horizon-a` for sheets. `horizon-b` for raised things: popovers and a hovered row. The switcher is Liquid Glass, as Spotlight is (see Switcher). Separate regions with a `rule` hairline, not with a shadow.
- **Text.** Each text color reaches 4.5:1 on every surface that carries it. `ink` for anything a person reads to act. `ink-muted` for notes, timestamps and actors. `ink-faint` only for section labels, accessory text (a link kind, a result kind) and placeholders.
- **Brand.** `moss` marks where you are: the active plot's dot, the primary button (with `on-moss` text), and the cursor. A selected row or tab is neutral, and a link label is `ink`. Use it sparingly. One screen should show it in at most three places.
- **Attention.** `needs-you` with `needs-you-wash`, and `done-unread` with `done-unread-wash`. Never use either hue for decoration or for a brand moment.
- **Calm structure.** Structure is felt, not seen, as in Raycast and Linear (the polish prototype, tickets 86 to 90). Hairlines, hover fills, selected fills and keycaps mix from the derived `ink` (`LoamColor.inkHairline` 8%, `inkFill` 5%, `inkSelected` 9%, `inkKey` 10%), so they follow every terminal theme. No view sets a fixed colour. Inactive rows are `ink-muted`; the selected or focused row is `ink`.
- **Errors and destruction.** `rust` with `rust-wash`. In the app, a destructive button or menu item takes the native destructive role, and a button shows its label in `rust`. In the web bundle, a destructive button is outlined in `rust` until you confirm it.
- **Focus.** Native controls draw the system focus ring. A control that Loam draws itself takes a 2px solid `focus` ring at 2px offset. It never relies on a glow.
- **The terminal theme.** `ansi-*` and `ansi-bright-*` are the Ghostty palette, with `bedrock` as background, `ink` as foreground, `cursor` and `selection`. `ansi-black` and `ansi-white` are low-contrast on purpose, as in every terminal theme.

Night is the first theme and the default. Day is a full theme, not an inversion: its `moss` and state hues are darker so they stay text-safe on white.

### Type

- **Chrome** uses the system face (SF Pro) at macOS sizes: `window-title`, `row`, `body` (13px), `caption` (11px), and `label` (10.5px uppercase, 0.08em tracking). The app does not use `label` now. Section labels in the sidebar, the plot panel and the switcher are sentence case, 12px, medium, `ink-faint`.
- **The panel** sets Where it stands at 13.5px in `ink` on its card, and What and Why at 13px in `ink-muted`. The toolbar title shows the plot name, so the panel does not show it. The app does not use `plot-name` (20px) now.
- **The terminal** uses `term`: JetBrains Mono, the Ghostty default, at 13px. Inline tool names, paths and change IDs use `code`.
- **The wordmark** is lowercase *loam* in Martian Mono (`wordmark`). Use it on onboarding, the empty window and the website. Never put it in the title bar.

### Spacing, radii, layout

A 4px grid: `space-1` to `space-8`. Rows are `space-2` × `space-3`. The plot panel pads `space-4` at the sides, its rows are 28px (properties) and 32px (repos and links), and its sections stand about `space-6` apart.

Radii grow with the size of the object: `radius-xs` chips, `radius-sm` rows and buttons, `radius-md` banners and popovers, `radius-lg` the switcher and sheets (the macOS 26 window corner). Count badges are `radius-pill`.

### Window regions

The window is the native macOS 26 frame. Three regions sit left to right, with a toolbar row across the top and an action bar across the bottom.

- **Sidebar.** The system glass sidebar, full height, with the window buttons inside it. It is a native split view sidebar item (180 to 400px). Loam paints no ground on it. Under the window buttons: a Search button with the switcher's keycaps, then the Needs you and Done, unread rows, which go to the next pane in that state (ticket 86). The tree follows.
- **Toolbar row.** One unified toolbar over the frame, with no glass over a pane. The sidebar toggle sits over the sidebar. The title is the active plot, and the subtitle is the main repo folder and its branch ("loam · main"). The subtitle follows a branch switch, because the app watches the repo's `HEAD`. A plot with no main repo has no subtitle. At the trailing edge: "N elsewhere need you" (only while the sidebar is hidden and a pane in another plot needs you), New session (⌘T), then Plot panel (⌘I).
- **The well.** Flexible. The tab bar and the panes sit in one card (`bedrock`) with a 12px radius and a 1px edge of the ink at 8% (ticket 88). An 8px margin of the chrome ground shows above the card, and on each side that no sidebar or panel touches. The tab bar is 40px high and starts under the toolbar, so no tab sits under the window buttons. Each tab is a 28px pill (radius 8, 12.5px medium text) with the pane symbol before its label. A `+` after the last tab starts a new session. The selected tab has a fill of the ink at 9% and a hairline. No tab has a moss underline.
- **Plot panel.** A plain split view item (260 to 520px, on the chrome ground, collapsible with ⌘I). It is not an inspector item, because macOS 26 puts an inspector on glass, and the glass made the panel a different tone from the rest of the frame. It pushes the well and never overlaps it. It runs the full height of the window. Its content is plain sections in a scroll view, the sibling of the sidebar (ticket 87):
  - Property rows at the top, in two columns: Main repo (folder and branch chip), Panes, Updated.
  - Where it stands is a raised card (`horizon-b`, radius 10, hairline) with the actor and time in its header. What and Why follow as plain text.
  - Repo and link rows are 32px: a symbol or service mark in `ink-muted`, the label in `ink`, the kind in `ink-faint` at the trailing edge.
  - Changes is a timeline of 20px avatars on a thin line. Undo shows on hover and on keyboard focus.
  - Callouts come first, as banners (`needs-you-wash`, or `rust-wash` for an error, radius 10). An error, the edit clash (Use current, Keep mine), the undo clash (Cancel, Undo and overwrite), and a missing link (Dismiss, Edit link) each have an SF Symbol in `rust`. "New since you looked" follows, with a clock symbol in `ink-muted`.
  - What, Why, and Where it stands are multiline text fields, one for each section, with a placeholder. Return adds a new line, and ⌘Return saves. Revert and Save show while a field has changes that are not saved. Save is the primary button.
  - Repos and Links have a `+` in the section header. It opens one inline add row: Return adds, and Escape cancels. Each row has a context menu and an `ellipsis.circle` menu that shows on hover, with the same actions.
  - Each add row has "Choose…" at its leading edge, which opens a native picker. The add repo row offers known repos and the git checkouts next to them under its field. The add link row puts the target first, and its label is optional.
  - A drop of files, folders, or URLs on the panel adds them. A git checkout becomes a repo, and anything else a link. A `moss` outline shows while a drag is over the panel.
  - Changes is the last section. A disclosure chevron opens the diff of a change.
  - The panel scrolls under the toolbar row, and its rows fade into the chrome ground there.
- **Action bar.** A 40px strip at the bottom of the middle column, under the well, on the chrome ground (ticket 89). It ends where the well ends, so with the plot panel open it gets narrower, as the well does. At the left: the plot name, a `/`, the focused pane, and for 6 seconds after a change, a toast such as "Claude set Where it stands". At the right: New session and Actions, each with its real keycaps. Actions (⌘J) opens the actions menu above the button: a 340px card on `horizon-b` with `shadow-raised`, the commands of the focused pane and the plot, and a filter field. See [ActionBar](components/ActionBar/README.md).

The quick switcher floats over everything right of the sidebar and above the action bar, so its preview has room when the plot panel is open.

**The chrome ground** (`LoamTheme.chrome`) is the one tone around the well: the toolbar row, the margin of the well, the gaps between the regions, the action bar, and the plot panel. It is `horizon-a` in Night and `horizon-o` in Day, so the `bedrock` well stands out from it in both appearances.

The frame behind the sidebar glass is `frame`: `bedrock` in Night, so the glass reads lighter than the frame, and `horizon-o` in Day, so the edge of the glass shows. This replaces the older rule that `horizon-o` is the ground of the title bar and the sidebar.

With `background-opacity` at 1 (the default), the frame and the panes are solid. Below 1 the window is translucent, as in Ghostty, and `background-blur` blurs the desktop behind it. Ticket 70 made the window always solid. Ticket 80 reverses that rule:

- Each pane draws its own background at the configured alpha. Nothing sits behind a pane, so the desktop shows through.
- Every region lets the same amount through, so the window reads as one sheet. The sidebar glass hides about 70% by itself, so the frame under it takes only the alpha that makes up the rest (`ChromePalette.frameUnderGlassAlpha`). At an opacity of 0.7 or below, the glass shows alone.
- The plot panel, the margin of the well, the gaps and the action bar stand on the chrome ground at the same alpha. The panel cards stay on top of it.
- The tab bar and the pane headers take their usual surface at the same alpha (`LoamTheme.ground`). The window then reads as one sheet.
- The pane area is clear. Each divider between panes is its own 1px `rule` layer. With no tab, the area is `bedrock` at the same alpha.

### The settings window

The settings window (⌘,) is a standard macOS settings window, with toolbar tabs (General, Terminal) and a grouped `Form` in each tab. It uses the system colours and the system appearance, not the chrome palette, because it holds no terminal and every macOS settings window looks this way. Paths show with `~`. A problem shows as a row with an SF Symbol: `exclamationmark.triangle.fill` in orange for a file error, `xmark.octagon.fill` in red for a `loam` binary that fails its check.

### Depth and shadow

Only things that float over the panes cast a shadow: `shadow-switcher` for the quick switcher and sheets, and `shadow-raised` for popovers and menus. Panels and sidebars sit flush, divided by `rule`.

### Motion

Motion is short and physical, and it explains where a thing came from.

- Hover and press: `duration-fast`.
- Selecting a row or a tab: `duration-base`, `ease-settle`.
- The switcher and sheets arrive in `duration-slow` with `ease-settle`: they drop 8px and fade in. They leave with `ease-lift`.
- A new change row grows in from 0 height. An undone change does not leave: it dims to `ink-muted` and its Undo turns into "undone HH:MM".
- **The Needs you halo** is the only loop: a ring that grows from the dot and fades, `duration-halo` per cycle, three cycles, then the dot stays still. It never loops while the pane has focus.
- Respect Reduce Motion: drop every transform and loop and keep only the color change.

### States

| State | Treatment |
| :- | :- |
| Hover | `ink` at 5% (`inkFill`), no border |
| Selected | `ink` at 9% (`inkSelected`), radius 7, `ink` text |
| Active plot | `moss` dot before the name |
| Needs you | `needs-you` filled dot, a `needs-you-wash` count badge, a halo on arrival |
| Done, unread | `done-unread` hollow ring, 1.5px stroke |
| Archived | under a collapsed "Archived" label, `ink-muted` names, no dots |
| Disabled | `ink-faint` text, no hover |
| Focus | the system ring on a native control; a 2px `focus` ring at 2px offset on a control that Loam draws |

## Iconography

Use **SF Symbols** in the app, at the `row` text size, weight medium, in `ink-muted` (selected: `ink`). The set, by role: plot `square.stack.3d.down.right`, link `link`, local folder `folder`, local file `doc`, vault note `doc.text`, Notion page `doc.richtext`, repo and main checkout `arrow.triangle.branch`, worktree `arrow.triangle.pull`, tab `rectangle.split.2x1`, shell pane `terminal`, menu action `command`, change `clock.arrow.circlepath`, undo `arrow.uturn.backward`, archive `archivebox`, switcher `magnifyingglass`.

**Service marks.** Three things take the mark of the service they belong to, in place of a symbol: a Claude session pane and a claude.ai link take the Claude mark, a GitHub link takes the GitHub mark, and a Linear link takes the Linear mark. The marks follow these rules:

- The source is Simple Icons (CC0). `LoamKit/Theme/BrandMark.swift` holds the paths and the version.
- Draw each mark unaltered, in one colour, tinted like the symbol it replaces (`ink-muted`, selected `ink`, missing `rust`). Never in brand colour, never cropped, never combined with another shape. This keeps to the GitHub, Anthropic and Linear guidelines.
- A mark names the service. It never stands for Loam.
- Notion and Obsidian get no mark. Notion's guidelines say not to use the standalone logo, and Obsidian asks third parties to ask first. Their links use `doc.richtext` and `doc.text`.
- `LoamIcon` in LoamKit maps each pane and link kind to its symbol or mark. Add a new mark there, with its licence and guideline links.

Attention states are drawn shapes, not symbols: an 8px filled circle for *Needs you* and an 8px ring with a 1.5px stroke for *Done, unread*.

The app icon is the mark: soil horizons under a moss sprout, on the Night ground. The source is `app/Resources/AppIcon.icon`, a layered Icon Composer icon with two groups. The sprout group is glass, and the strata group is flat. macOS 26 makes the dark, tinted, and clear variants. `scripts/build-icon.sh` compiles it at install. The name still sets in the `wordmark` style.
