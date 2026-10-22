import AppKit
import LoamKit
import SwiftUI

/// The PR popover (ticket 109, boards 1.2, 2.1 and 5.3): a card of 360 pt on `horizon-b` with
/// `shadow-raised`, over the window. It opens from a control (`PopoverAnchor`), below it when there is
/// room, else above. Escape or a click outside closes it, and Return runs the primary button. It is an
/// overlay in the window, like the actions menu, so the keys of the window reach it and the driver can
/// press its buttons. `PRPopoverContent` says what it shows.
struct PRPopoverView: View {
    let app: AppModel
    /// Where the popover opens from, in the space of this view (the origin is the top left corner).
    let anchorRect: () -> CGRect
    /// Return, or a click on the primary button.
    let runPrimary: (PRPrimaryAction) -> Void
    @FocusState private var focused: Bool
    @State private var size = CGSize.zero
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 360
    private static let radius = LoamTheme.radiusMd

    var body: some View {
        let model = app.prPopover
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { app.closePullRequest() }
                if let status = model.worktreeID.flatMap({ app.worktreeStatus($0) }) {
                    let frame = PopoverPlacement.frame(size: size, anchor: anchorRect(), in: CGRect(origin: .zero, size: proxy.size))
                    card(PRPopoverContent(status, attemptedAt: model.answeredAt), status: status)
                        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
                        // The card has no size until it is laid out once, and it would show in the wrong place.
                        .opacity(size == .zero ? 0 : 1)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) { app.closePullRequest(); return .handled }
        .onKeyPress(.return) {
            guard let primary = currentPrimary else { return .ignored }
            runPrimary(primary)
            return .handled
        }
        .task(id: model.openCount) {
            // The hosting view becomes first responder after this view appears.
            for _ in 0..<5 {
                focused = true
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private var currentPrimary: PRPrimaryAction? {
        app.prPopover.worktreeID.flatMap { app.worktreeStatus($0) }.flatMap { PRPopoverContent($0).primary }
    }

    // MARK: Card

    private func card(_ content: PRPopoverContent, status: WorktreeStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let stage = content.stage { header(stage, content) }
            titleBlock(content)
            if let notice = content.notice { footnote(notice, id: "pr-popover-notice") }
            rows(content)
            if let note = content.stageNote { footnote(note, id: "pr-popover-stage-note") }
            if !content.failedChecks.isEmpty { failedChecks(content.failedChecks) }
            if content.primary != nil || !content.secondary.isEmpty { buttons(content, status: status) }
            if let note = app.prPopover.note { footnote(note, id: "pr-popover-note") }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(width: Self.width)
        .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: Self.radius))
        .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(LoamColor.inkHairline))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius))
        .shadow(color: Color(nsColor: LoamTheme.shadowRaised).opacity(LoamTheme.shadowRaisedAlpha(dark: scheme == .dark)),
                radius: 12, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
        .accessibilityIdentifier("pr-popover")
    }

    /// The stage symbol and name in the colour of the stage, and the time of the last answer of GitHub.
    private func header(_ stage: WorktreeStage, _ content: PRPopoverContent) -> some View {
        HStack(spacing: 6) {
            StageGlyph(stage: stage, size: 13)
            Text(stage.words)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LoamColor.stage(stage.tone))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("pr-popover-stage")
            if let time = app.prPopover.isRefreshing ? "Updating\u{2026}" : content.updated {
                Text(time)
                    .font(.system(size: 11))
                    .foregroundStyle(LoamColor.inkFaint)
                    .accessibilityIdentifier("pr-popover-updated")
            }
        }
    }

    private func titleBlock(_ content: PRPopoverContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if content.hasPullRequest {
                Text(content.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineSpacing(2)
                    .accessibilityIdentifier("pr-popover-title")
                Text(content.subtitle)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LoamColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("pr-popover-subtitle")
            } else {
                Text(content.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("pr-popover-title")
                Text(content.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LoamColor.inkMuted)
                    .accessibilityIdentifier("pr-popover-subtitle")
            }
        }
        .foregroundStyle(LoamColor.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-popover-heading")
    }

    /// Checks, Review, Base and Conflicts, or the rows of a worktree with no PR, between two hairlines.
    private func rows(_ content: PRPopoverContent) -> some View {
        VStack(spacing: 0) {
            ForEach(content.rows, id: \.label) { row in
                PropertyRow(label: row.label) {
                    statusLineText(row.parts, color: LoamColor.ink, separator: LoamColor.ink)
                        .font(row.isCode ? .system(size: 12, design: .monospaced) : nil)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(row.parts.map(\.text).joined(separator: StatusLine.separator))
                .accessibilityIdentifier("pr-popover-row-\(row.label.lowercased())")
            }
        }
        .padding(.top, content.hasPullRequest ? 4 : 6)
        .padding(.bottom, content.hasPullRequest ? 4 : 0)
        .overlay(alignment: .top) { LoamColor.inkHairline.frame(height: 1) }
        .overlay(alignment: .bottom) {
            if content.hasPullRequest { LoamColor.inkHairline.frame(height: 1) }
        }
    }

    // MARK: Failed checks

    private func failedChecks(_ checks: [PRPopoverContent.FailedCheckRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Failed checks")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoamColor.inkFaint)
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    FailedCheckRowView(check: check, index: index)
                }
            }
            .padding(.horizontal, -8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-popover-failed-checks")
    }

    // MARK: Buttons

    private func buttons(_ content: PRPopoverContent, status: WorktreeStatus) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: content.hasPullRequest ? 3 : 2)
        return VStack(spacing: 8) {
            if let primary = content.primary {
                Button { runPrimary(primary) } label: { Text(primary.title).frame(maxWidth: .infinity) }
                    .loamPrimaryButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("pr-popover-primary")
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(content.secondary, id: \.self) { action in
                    secondary(action, content: content, status: status)
                }
            }
        }
    }

    private func secondary(_ action: PRSecondaryAction, content: PRPopoverContent, status: WorktreeStatus) -> some View {
        let running = app.prPopover.running
        return Button {
            switch action {
            case .rerunFailed: Task { await app.rerunFailedChecks() }
            case .updateBranch: Task { await app.updateBranch() }
            case .openOnGitHub:
                if let page = content.githubPage { SystemActions.open(page) }
            case .copyBranchName:
                SystemActions.copy(status.worktree.branch)
                app.prPopover.say("Copied the branch name.")
            }
        } label: {
            HStack(spacing: 6) {
                Text(action.title)
                if running == action { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
            }
        }
        .buttonStyle(PopoverButtonStyle())
        // A command of the core runs one at a time. Open and Copy run on this Mac and never wait.
        .disabled(running != nil && (action == .rerunFailed || action == .updateBranch))
        .accessibilityIdentifier("pr-popover-\(action.rawValue)")
    }

    private func footnote(_ text: String, id: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .lineSpacing(2)
            .foregroundStyle(LoamColor.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(id)
    }
}

/// A failed check: the `rust` symbol, the name in the mono face, how long it ran, and a link to its log.
private struct FailedCheckRowView: View {
    let check: PRPopoverContent.FailedCheckRow
    let index: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StageGlyph(stage: .checksFailed, size: 13)
            Text(check.name)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LoamColor.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = check.duration {
                Text(duration).font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint).monospacedDigit()
            }
            if let log = check.log {
                Button("Log") { SystemActions.open(log) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? LoamColor.ink : LoamColor.inkMuted)
                    .onHover { hovering = $0 }
                    .accessibilityIdentifier("pr-popover-log-\(index)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(check.name)
        .accessibilityIdentifier("pr-popover-check-\(index)")
    }
}

/// A smaller button of the popover (the `.b2` of the boards): 28 pt high, radius 6, a fill and an `edge` border.
private struct PopoverButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(LoamColor.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(configuration.isPressed ? LoamColor.inkSelected : LoamColor.inkFill, in: shape)
            .overlay(shape.strokeBorder(LoamColor.edge))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(shape)
    }
}
