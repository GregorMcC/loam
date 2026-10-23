import LoamKit
import SwiftUI

/// The bottom action bar (ticket 89, docs/design/components/ActionBar): a 40 pt strip under the
/// well and the plot panel, right of the sidebar. It stands on the frame, which the column and the
/// split view paint under it, so it has no ground of its own and no top rule.
struct ActionBarView: View {
    let bar: ActionBarModel
    let review: ReviewModel
    let app: AppModel
    /// Tells the window where the chip is, for a popover that the chip or a key opens.
    let chipProbe: AnchorProbe
    /// The keycaps of New session and of Actions, from the menu bar.
    let newSessionKeys: () -> [String]
    let actionsKeys: () -> [String]
    let newSession: () -> Void
    let toggleActions: () -> Void

    static let height: CGFloat = 40
    /// The room left of the plot name.
    static let leadingInset: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            // The toast and the PR chip share the place after the pane label, and the toast wins while it
            // shows. A narrow bar drops the toast, then the words of the chip. A bar that still has no room
            // cuts the pane label short, so the chip stays and the buttons stay in view.
            ViewThatFits(in: .horizontal) {
                context(bar.trailing, words: true)
                context(chipOnly, words: true)
                context(chipOnly, words: false)
                context(chipOnly, words: false, cutsLabel: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BarButton(title: "New session", keys: newSessionKeys(), id: "action-bar-new-session", isOn: false, action: newSession)
            LoamColor.ink.opacity(0.13).frame(width: 1, height: 16)
            BarButton(title: "Actions", keys: actionsKeys(), id: "action-bar-actions", isOn: bar.menu.isOpen, action: toggleActions)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 8)
        .frame(height: Self.height)
        // The fade-out timer runs here, not on the toast: in a narrow bar the toast does not show,
        // and it must still clear.
        .task(id: bar.toastID) {
            let id = bar.toastID
            try? await Task.sleep(for: .seconds(ActionBarModel.toastSeconds))
            withAnimation(.easeOut(duration: LoamTheme.durationSlow)) { bar.clearToast(id: id) }
        }
        .onChange(of: review.changes.last?.id, initial: true) {
            // The first read of the log fills it. A plot always has its creation change.
            guard !review.changes.isEmpty else { return }
            bar.changesArrived(review.changes, activePlot: app.workspace.activePlotID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("action-bar")
    }

    private var chipOnly: ActionBarModel.Trailing { bar.chip.map { .chip($0) } ?? .nothing }

    /// `cutsLabel` lets the pane label end in an ellipsis. The other variants keep their full size, so
    /// `ViewThatFits` can tell whether they fit.
    private func context(_ trailing: ActionBarModel.Trailing, words: Bool, cutsLabel: Bool = false) -> some View {
        HStack(spacing: 6) {
            LoamIconView(icon: bar.isHome ? .home : .plot, size: 12, color: LoamColor.moss)
                .padding(.trailing, 2)
            Text(bar.plotName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LoamColor.ink)
                .accessibilityIdentifier("action-bar-plot")
            if !bar.paneLabel.isEmpty {
                Text("/").font(.system(size: 12.5)).foregroundStyle(LoamColor.inkFaint)
                Text(bar.paneLabel)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LoamColor.inkMuted)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("action-bar-pane")
            }
            switch trailing {
            case .toast(let toast):
                HStack(spacing: 6) {
                    let notice = bar.toastKind == .notice
                    Image(systemName: notice ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: notice ? 11 : 10, weight: .semibold))
                        .foregroundStyle(notice ? LoamColor.inkMuted : LoamColor.moss)
                    Text(toast).font(.system(size: 12.5)).foregroundStyle(LoamColor.inkFaint)
                }
                .padding(.leading, 14)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("action-bar-toast")
            case .chip(let mark):
                // The popover finds the chip through `chipProbe`, as for a key. A toast that hides the chip
                // for a while does not close it.
                PullRequestChip(mark: mark, words: words, probe: chipProbe) {
                    if let id = app.focusedWorktree?.id { app.openPullRequest(id, anchor: .actionBar) }
                }
                .fixedSize()
                .layoutPriority(1)
                .padding(.leading, 8)
            case .nothing:
                EmptyView()
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: !cutsLabel, vertical: true)
        .animation(LoamAnimation.fast, value: bar.trailing)
    }
}

/// The PR of the focused pane's worktree (ticket 109, board 1.1): the number in `ink-muted`, the stage symbol
/// and, when there is room, the stage in words in the colour of the stage. A click opens the PR popover above it.
private struct PullRequestChip: View {
    let mark: StageMark
    let words: Bool
    let probe: AnchorProbe
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                if let label = mark.label {
                    Text(label).font(.system(size: 12.5)).foregroundStyle(LoamColor.inkMuted).monospacedDigit()
                }
                StageGlyph(stage: mark.stage, size: 12)
                if words {
                    Text(mark.stage.words).font(.system(size: 12.5)).foregroundStyle(LoamColor.stage(mark.tone))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(LoamColor.inkHairline))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(AnchorReader(probe: probe))
        .help(mark.tooltip)
        .accessibilityLabel(mark.spoken)
        .accessibilityIdentifier("action-bar-pr-chip")
    }
}

/// A text button of the bar with its keycaps: `ink` text, the ink at 9% on hover and while its
/// menu is open.
private struct BarButton: View {
    let title: String
    let keys: [String]
    let id: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LoamColor.ink)
                    .padding(.trailing, 4)
                ForEach(Array(keys.enumerated()), id: \.offset) { Keycap(text: $1) }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(LoamColor.inkSelected.opacity(hovering || isOn ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

/// The actions menu (⌘J): a card above the Actions button with the focused pane's and the plot's
/// actions, each with its real keycaps, and a search field at the bottom. Arrow keys move, Return
/// runs, Escape closes. A click outside the card closes it. While an input method composes text in the filter, Escape
/// cancels the composed text and the menu stays open.
struct ActionsMenuView: View {
    let menu: ActionMenuModel
    let run: (AppCommand) -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool
    /// The window of the menu, to ask whether an input method composes text in the filter.
    @State private var window = WindowRef()

    static let width: CGFloat = 340
    /// From the right end of the bar, and from the bottom (over the bar).
    static let trailing: CGFloat = 10
    static let bottom: CGFloat = ActionBarView.height + 6

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
            card
                .padding(.trailing, Self.trailing + menu.trailingInset)
                .padding(.bottom, Self.bottom)
        }
        .background(WindowReader(ref: window))
        .task(id: menu.openCount) {
            // The hosting view becomes first responder after this view appears.
            for _ in 0..<5 {
                fieldFocused = true
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private var card: some View {
        let selected = menu.selected
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(menu.visible) { section in
                    Text(section.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LoamColor.inkFaint)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        .accessibilityHidden(true)
                    ForEach(section.items) { item in
                        row(item, selected: item == selected)
                    }
                }
                if menu.visible.isEmpty {
                    Text("No actions")
                        .font(.system(size: 13))
                        .foregroundStyle(LoamColor.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .padding(6)
            LoamColor.inkHairline.frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoamColor.inkFaint)
                TextField("Search actions", text: Binding(get: { menu.query }, set: { menu.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(LoamColor.ink)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("actions-search")
                    .onSubmit { if let command = menu.runSelected() { run(command) } }
                    .onKeyPress(.downArrow) { menu.move(1); return .handled }
                    .onKeyPress(.upArrow) { menu.move(-1); return .handled }
                    .onKeyPress(.escape) {
                        // Escape that cancels an input method composition is the input method's.
                        guard !window.isComposing else { return .ignored }
                        close()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
        }
        .frame(width: Self.width)
        .loamFloating(.raised, ground: LoamColor.horizonB, radius: LoamTheme.radiusMd)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actions-menu")
    }

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LoamColor.inkMuted)
                .frame(width: 16)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(LoamColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) { ForEach(Array(item.keys.enumerated()), id: \.offset) { Keycap(text: $1) } }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(selected ? LoamColor.inkSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            menu.select(item)
            if let command = menu.runSelected() { run(command) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("actions-row-\(item.title)")
    }
}
