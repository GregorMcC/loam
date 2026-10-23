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
    /// Where the popover opens from, in the space of this view. The window keeps it at the control.
    let place: PopoverPlace
    /// Return, or a click on the primary button.
    let runPrimary: (PRPrimaryAction) -> Void
    @FocusState private var focused: Bool
    /// The goal field of a worktree with no PR (ticket 115) holds the keys while you edit it.
    @FocusState private var goalFocused: Bool
    /// The window, to ask if an input method composes in the goal field.
    @State private var window = WindowRef()
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 360
    private static let radius = LoamTheme.radiusMd

    var body: some View {
        let model = app.prPopover
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { app.closePullRequest() }
            if let status = model.worktreeID.flatMap({ app.worktreeStatus($0) }) {
                let content = PRPopoverContent(status, attemptedAt: model.attemptedAt)
                // A refresh can take the row of the passed checks away. Then no list shows, and the card picks its side
                // again. `AppModel` closes the list in the same change.
                PopoverLayout(anchor: place.anchor, open: model.openCount,
                              listOpen: model.showsPassedChecks && !content.passedChecks.isEmpty) {
                    card(content, status: status)
                        .id(model.openCount)
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .background(WindowReader(ref: window))
        .onKeyPress(.escape) {
            // Escape that cancels an input method composition is the input method's.
            guard !window.isComposing else { return .ignored }
            // Escape ends the goal edit first, whichever view has the focus. The next one closes the popover.
            if model.goalDraft != nil { app.cancelGoalEdit() } else { app.closePullRequest() }
            return .handled
        }
        .onKeyPress(.return) {
            // Return in the goal field saves the goal. It never runs the button of the card.
            guard model.goalDraft == nil, let primary = currentPrimary else { return .ignored }
            runPrimary(primary)
            return .handled
        }
        // The keys go back to the card when the goal edit ends, so Escape closes the popover and not nothing.
        .onChange(of: model.goalDraft == nil) { if model.goalDraft == nil { focused = true } }
        .task(id: model.openCount) {
            // The hosting view becomes first responder after this view appears. A popover that closed meanwhile
            // takes no keys: they went back to where they were.
            for _ in 0..<5 {
                guard app.prPopover.isOpen else { return }
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
        cardContent(content, status: status)
            .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: Self.radius))
            .overlay(RoundedRectangle(cornerRadius: Self.radius).strokeBorder(LoamColor.inkHairline))
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .shadow(color: Color(nsColor: LoamTheme.shadowRaised).opacity(LoamTheme.shadowRaisedAlpha(dark: scheme == .dark)),
                    radius: 12, y: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(content.title)
            .accessibilityIdentifier("pr-popover")
    }

    private func cardContent(_ content: PRPopoverContent, status: WorktreeStatus) -> some View {
        // One plan for each render: the button and the line under the buttons say the same thing.
        let plan = content.primary == nil ? nil : app.sendPlan(for: status.worktree.id)
        return VStack(alignment: .leading, spacing: 12) {
            if let stage = content.stage { header(stage, content) }
            titleBlock(content)
            if let notice = content.notice { footnote(notice, id: "pr-popover-notice") }
            rows(content)
            if let note = content.stageNote { footnote(note, id: "pr-popover-stage-note") }
            if !content.failedChecks.isEmpty { failedChecks(content) }
            if content.primary != nil || !content.secondary.isEmpty { buttons(content, status: status, plan: plan) }
            if let plan { footnote(plan.footnote, id: "pr-popover-send-note") }
            if let note = app.prPopover.note { footnote(note, id: "pr-popover-note") }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(width: Self.width)
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

    /// Checks, Review, Base and Conflicts, or the rows of a worktree with no PR, between two hairlines. A worktree with no
    /// PR starts with its Goal and its Link (ticket 115, board WorktreeGoal).
    private func rows(_ content: PRPopoverContent) -> some View {
        VStack(spacing: 0) {
            if let goal = content.goal { goalRow(goal) }
            if let link = content.link { linkRow(link) }
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

    // MARK: Goal and link

    /// The Goal row: the goal as a button that opens the edit, or the field. Return saves, Escape cancels. A goal of more
    /// than 20 words saves, with the soft limit under the field in `needs`.
    private func goalRow(_ goal: PRPopoverContent.Goal) -> some View {
        let model = app.prPopover
        let note = model.goalProblem ?? model.goalDraft.flatMap(WorktreeGoal.warning(for:))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Goal").foregroundStyle(LoamColor.inkFaint).frame(width: 84, alignment: .leading)
                if model.goalDraft != nil {
                    TextField("Goal", text: Binding(get: { model.goalDraft ?? "" }, set: { model.setGoalDraft($0) }))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($goalFocused)
                        .onSubmit { Task { await app.saveGoalEdit() } }
                        .onKeyPress(.escape) {
                            guard !window.isComposing else { return .ignored }
                            app.cancelGoalEdit()
                            return .handled
                        }
                        .onAppear { goalFocused = true }
                        .disabled(model.isSavingGoal)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .background(LoamColor.horizonA, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LoamColor.edge))
                        .accessibilityLabel("Goal")
                        .accessibilityIdentifier("pr-popover-goal-field")
                } else {
                    GoalButton(text: goal.text) { app.beginGoalEdit() }
                }
            }
            .font(.system(size: 12.5))
            .frame(minHeight: 28)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(model.goalProblem == nil ? LoamColor.needsYou : LoamColor.rust)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 94)
                    .accessibilityIdentifier("pr-popover-goal-note")
            }
        }
    }

    /// The Link row: the issue that the work started from, with the mark of its service. A click opens it.
    private func linkRow(_ link: PRPopoverContent.LinkRow) -> some View {
        HStack(spacing: 10) {
            Text("Link").foregroundStyle(LoamColor.inkFaint).frame(width: 84, alignment: .leading)
            let label = HStack(spacing: 6) {
                LoamIconView(icon: link.icon, size: 12)
                Text(link.label).lineLimit(1).truncationMode(.tail)
            }
            if let url = link.url {
                Button { SystemActions.open(url) } label: { label.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(link.label)
                    .accessibilityIdentifier("pr-popover-link")
            } else {
                label.accessibilityElement(children: .combine).accessibilityIdentifier("pr-popover-link")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LoamColor.ink)
        .frame(height: 28)
        .help(link.url?.absoluteString ?? link.label)
    }

    // MARK: Failed checks

    /// The failed checks, and the row at their end that opens the passed checks (ticket 116).
    private func failedChecks(_ content: PRPopoverContent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Failed checks")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LoamColor.inkFaint)
            VStack(spacing: 0) {
                ForEach(Array(content.failedChecks.enumerated()), id: \.offset) { index, check in
                    CheckRowView(check: check, kind: .failed, index: index)
                }
                if !content.passedChecks.isEmpty {
                    PassedChecksView(title: content.passedTitle, checks: content.passedChecks, isOpen: app.prPopover.showsPassedChecks,
                                     onToggle: app.togglePassedChecks)
                }
            }
            .padding(.horizontal, -8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-popover-failed-checks")
    }

    // MARK: Buttons

    private func buttons(_ content: PRPopoverContent, status: WorktreeStatus, plan: SendPlan?) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: content.hasPullRequest ? 3 : 2)
        return VStack(spacing: 8) {
            if let primary = content.primary {
                Button { runPrimary(primary) } label: { primaryLabel(primary, plan: plan) }
                    .loamPrimaryButton()
                    .controlSize(.large)
                    .accessibilityLabel(plan?.buttonTitle ?? primary.title)
                    .accessibilityValue(plan?.typeTarget ?? "")
                    .accessibilityIdentifier("pr-popover-primary")
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(content.secondary, id: \.self) { action in
                    secondary(action, content: content, status: status)
                }
            }
        }
    }

    /// The words of the primary button. A Send button that types names the session that gets the prompt, in
    /// `on-moss` at 75% (board 2.1, ticket 110). When Loam cannot type, the button says Copy prompt or Start
    /// session with prompt, and the line under the buttons says why (`SendPlan`).
    private func primaryLabel(_ primary: PRPrimaryAction, plan: SendPlan?) -> some View {
        HStack(spacing: 8) {
            Text(plan?.buttonTitle ?? primary.title)
            if let pane = plan?.typeTarget {
                Text(pane)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.75)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
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
                app.copyText(status.worktree.branch)
                app.prPopover.say("Copied the branch name.")
            }
        } label: {
            HStack(spacing: 6) {
                Text(action.title)
                if running == action { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12) }
            }
        }
        .buttonStyle(PopoverButtonStyle())
        // A command of the core runs one at a time for a worktree. Open and Copy run on this Mac and never wait.
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

/// Places the card of the popover. It reads the size of the card and puts the card at its frame in the same layout
/// pass, so a card that grows, such as one with a list that opens, is never laid out at its new size and its old
/// place (ticket 116). The card is as tall as its content and at most as tall as the window holds
/// (`PopoverPlacement.maxHeight`), so only a list of passed checks that is too tall for it shrinks and scrolls.
private struct PopoverLayout: Layout {
    /// Where the popover opens from, in the space of this layout.
    let anchor: CGRect
    /// The number of the open, and whether the passed checks show. They say which side of the anchor the card
    /// stands on (`PopoverMeasure`).
    let open: Int
    let listOpen: Bool

    func makeCache(subviews: Subviews) -> PopoverMeasure { PopoverMeasure() }

    /// The cache keeps the side of the card from one pass to the next. The default would make a new cache whenever
    /// the anchor or the list changes.
    func updateCache(_ cache: inout PopoverMeasure, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout PopoverMeasure) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout PopoverMeasure) {
        guard let card = subviews.first else { return }
        let container = CGRect(origin: .zero, size: bounds.size)
        let size = card.sizeThatFits(ProposedViewSize(width: container.width, height: PopoverPlacement.maxHeight(in: container)))
        let side = cache.measure(size, open: open, listOpen: listOpen, anchor: anchor, in: container)
        let frame = PopoverPlacement.frame(size: size, anchor: anchor, side: side, in: container)
        card.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(size))
    }
}

/// The symbol of a passed check, and of the row that opens the passed checks.
private struct PassedGlyph: View {
    var body: some View { LoamIconView(icon: .symbol("checkmark.circle"), size: 13, color: LoamColor.inkMuted) }
}

/// A check of one of the two lists: a symbol, the name in the mono face, how long it ran, and a link to its
/// log. A failed check has the `rust` symbol, and a passed check has `checkmark.circle` in `ink-muted`.
private struct CheckRowView: View {
    enum Kind {
        case failed
        case passed

        func checkID(_ index: Int) -> String {
            switch self {
            case .failed: "pr-popover-check-\(index)"
            case .passed: "pr-popover-passed-check-\(index)"
            }
        }

        func logID(_ index: Int) -> String {
            switch self {
            case .failed: "pr-popover-log-\(index)"
            case .passed: "pr-popover-passed-log-\(index)"
            }
        }
    }

    /// The height of a row, which the board sets for both lists.
    static let height: CGFloat = 30

    let check: PRPopoverContent.CheckRow
    let kind: Kind
    let index: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            switch kind {
            case .failed: StageGlyph(stage: .checksFailed, size: 13)
            case .passed: PassedGlyph()
            }
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
                    .accessibilityIdentifier(kind.logID(index))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(check.name)
        .accessibilityIdentifier(kind.checkID(index))
    }
}

/// The row "12 passed" and the list that it opens in place, under the row (ticket 116, board 2.1). A click on the row
/// opens the list and turns the chevron down, and a second click closes it. The list scrolls inside the card when
/// the card is taller than the window allows (`PopoverPlacement.maxHeight`). The row takes no keys: Escape still
/// closes the popover with the list open. `PRPopoverModel.showsPassedChecks` says whether the list shows, because
/// the placement of the card needs it too.
private struct PassedChecksView: View {
    let title: String
    let checks: [PRPopoverContent.CheckRow]
    let isOpen: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            toggle
            if isOpen {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                            CheckRowView(check: check, kind: .passed, index: index)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                // The list is as tall as its rows, or less when the card has no more room.
                .frame(maxHeight: CGFloat(checks.count) * CheckRowView.height)
                .accessibilityIdentifier("pr-popover-passed-list")
            }
        }
    }

    private var toggle: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                PassedGlyph()
                Text(title)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Only the turn is animated. The card grows when the list opens, and an animated position would make
                // the chevron fly from the old place of the row to the new one.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .animation(LoamAnimation.settle) { $0.rotationEffect(.degrees(isOpen ? 90 : 0)) }
            }
            .foregroundStyle(LoamColor.inkMuted)
            .padding(.horizontal, 8)
            .frame(height: CheckRowView.height)
            .background(hovering ? LoamColor.inkFill : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Shown" : "Hidden")
        .accessibilityIdentifier("pr-popover-passed-toggle")
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

/// The goal in the Goal row. A worktree with no goal invites one. A hover shows the pencil on a neutral fill, and a click
/// opens the edit (board WorktreeGoal).
private struct GoalButton: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text.isEmpty ? PRPopoverContent.Goal.placeholder : text)
                    .foregroundStyle(text.isEmpty ? LoamColor.inkFaint : LoamColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(LoamColor.inkMuted)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(LoamColor.hoverFill).opacity(hovering ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -6)
        .onHover { hovering = $0 }
        .help(text.isEmpty ? "Add a goal" : text)
        .accessibilityLabel(text.isEmpty ? PRPopoverContent.Goal.placeholder : "Goal, \(text)")
        .accessibilityHint("Edit the goal")
        .accessibilityIdentifier("pr-popover-goal")
    }
}
