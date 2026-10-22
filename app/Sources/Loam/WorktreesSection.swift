import AppKit
import LoamKit
import SwiftUI

/// The Worktrees section of the plot panel (ticket 108), after Why and before Repos. A header with the
/// age of the data and a `+` for a new worktree, the callouts about `gh`, and one row for each worktree
/// of the plot in the order of the sidebar. The text of a row comes from `StatusLine` and the mark from
/// the stage table (`WorktreeStage`), the same as the tooltip in the sidebar. A row that is ready to merge has
/// a Land… pill, and a row that is merged shows faded with a Remove… pill (ticket 112). A row that a land
/// removes leaves with the row animation.
struct WorktreesSection: View {
    let app: AppModel
    let plot: String
    let timeZone: TimeZone

    var body: some View {
        let rows = app.worktrees[plot] ?? []
        VStack(alignment: .leading, spacing: 2) {
            // The age grows with the clock, so the header reads the time again each minute.
            TimelineView(.everyMinute) { context in
                PanelSectionHeader(
                    title: "Worktrees",
                    detail: ShipAge.label(for: rows, now: context.date, timeZone: timeZone).map { ($0, "panel-worktrees-age") },
                    add: ("New worktree\u{2026}", "panel-add-worktree")
                ) { WorktreeDialogs.askNewWorktree(plot: plot, model: app) }
            }
            ForEach(app.shipNotices(for: plot), id: \.self) { ShipNoticeCard(app: app, notice: $0) }
            ForEach(rows, id: \.worktree.id) {
                WorktreeRowView(app: app, row: $0, timeZone: timeZone).transition(LoamAnimation.growIn)
            }
            if rows.isEmpty {
                EmptyRow(text: "No worktrees")
            }
        }
        .animation(LoamAnimation.lift, value: rows.map(\.worktree.id))
    }
}

// MARK: Notices

/// A problem with `gh`, in a neutral callout. Dismiss hides it until the app quits. Sign in, for a
/// signed-out `gh`, opens a shell pane with `gh auth login` typed and not sent.
private struct ShipNoticeCard: View {
    let app: AppModel
    let notice: ShipNotice

    var body: some View {
        CalloutCard(tone: .neutral) {
            message
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("panel-ship-notice-\(slug)")
            TrailingButtons(pill: true) {
                Button("Dismiss") { app.dismiss(notice) }
                    .accessibilityIdentifier("panel-ship-dismiss-\(slug)")
                if notice == .ghSignedOut {
                    Button("Sign in") { Task { await app.signInToGitHub() } }
                        .accessibilityIdentifier("panel-ship-sign-in")
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// The words, then the command in a monospaced face.
    private var message: Text {
        let words = Text(notice.message).font(.system(size: 12.5)).foregroundStyle(LoamColor.ink)
        guard let command = notice.command else { return words }
        let code = Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(LoamColor.ink)
        return Text("\(words) \(code)")
    }

    private var slug: String { String(describing: notice) }
}

// MARK: Rows

/// One worktree: the stage mark, the branch with its PR number, and the status line. A click opens the
/// PR popover (ticket 109). The hover menu and the context menu hold `WorktreeActions`, the same as the
/// sidebar row. The pill before the menu is Land… at Ready to merge, and Remove… at Merged, where the row is
/// faded (ticket 112, boards 4.1 and 5.1).
private struct WorktreeRowView: View {
    let app: AppModel
    let row: WorktreeStatus
    let timeZone: TimeZone
    @State private var probe = AnchorProbe()

    var body: some View {
        let line = StatusLine(of: row, timeZone: timeZone)
        let faded = row.stage == .merged && !row.missing
        HoverMenuRow(menuLabel: "Worktree actions", menuID: "panel-worktree-menu-\(row.worktree.id)",
                     kind: row.missing ? "gone" : nil, minHeight: 44, trailingInset: 28) {
            HStack(spacing: 8) {
                StageSlot(stage: row.stage)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(row.worktree.branch)
                            .font(.system(size: 13))
                            .foregroundStyle(row.missing || faded ? LoamColor.inkFaint : LoamColor.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let number = row.pr?.number {
                            Text("#\(number)").font(.system(size: 13)).foregroundStyle(faded ? LoamColor.inkFaint : LoamColor.inkMuted).fixedSize()
                        }
                    }
                    statusLineText(line.parts, color: faded ? LoamColor.inkFaint : LoamColor.inkMuted,
                                   separator: faded ? LoamColor.inkFaint : LoamColor.inkMuted)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                pill
            }
            // A narrow panel cuts a long line, so the tooltip holds all of it.
            .help(line.text)
        } actions: {
            WorktreeActions(model: app, id: row.worktree.id)
        }
        .background(AnchorReader(probe: probe))
        .onTapGesture { showPullRequest() }
        .accessibilityLabel(label(line))
        .accessibilityIdentifier("panel-worktree-\(row.worktree.id)")
        .accessibilityAction { showPullRequest() }
    }

    /// Land… for a PR that is ready to merge, in the pill style of the panel and not in `moss`. Remove… for a worktree
    /// that is merged: a worktree that you kept, or one that was merged on GitHub.
    @ViewBuilder private var pill: some View {
        if row.stage == .readyToMerge, !row.missing {
            Button(PRPrimaryAction.land.title) { app.openLandSheet(row.worktree.id) }
                .buttonStyle(PanelPillStyle())
                .foregroundStyle(LoamColor.ink)
                .accessibilityIdentifier("panel-worktree-land-\(row.worktree.id)")
        } else if row.stage == .merged, !row.missing {
            Button("Remove\u{2026}") { WorktreeDialogs.askRemove(row.worktree.id, model: app) }
                .buttonStyle(PanelPillStyle())
                .foregroundStyle(LoamColor.ink)
                .accessibilityIdentifier("panel-worktree-remove-\(row.worktree.id)")
        }
    }

    private func showPullRequest() {
        app.openPullRequest(row.worktree.id, anchor: probe.anchor)
    }

    /// "native-panel #16, 2 of 3 checks failed · 3 behind main", for VoiceOver and the driver.
    private func label(_ line: StatusLine) -> String {
        let number = row.pr.map { " #\($0.number)" } ?? ""
        return "\(row.worktree.branch)\(number), \(line.text)"
    }
}

/// The mark of a stage in the 16pt slot at the leading edge. A worktree with no stage shows a dot, so
/// the rows line up. The tooltip names the stage.
private struct StageSlot: View {
    let stage: WorktreeStage?

    var body: some View {
        Group {
            if let stage, stage != .noStage {
                StageGlyph(stage: stage, size: 13)
            } else {
                Text("\u{2022}").font(.system(size: 12)).foregroundStyle(LoamColor.inkFaint)
            }
        }
        .frame(width: 16)
        .help(stage?.words ?? "")
        .accessibilityHidden(true)
    }
}
