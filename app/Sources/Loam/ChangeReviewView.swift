import LoamKit
import SwiftUI

/// "New since you looked" (a callout at the top of the plot panel) and the changes (the last
/// section). Spec 8.6, ticket 87. Rows follow docs/design/components/ChangeRow: a timeline.
struct NewSinceSection: View {
    let review: ReviewModel
    let plot: String

    var body: some View {
        let new = review.newChanges(plot: plot)
        if !new.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("New since you looked").foregroundStyle(LoamColor.ink)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(LoamColor.inkMuted)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .accessibilityIdentifier("panel-new-since")
                ChangeTimeline(review: review, changes: new, diffOpen: true)
            }
            .animation(LoamAnimation.arrive, value: new.map(\.id))
        }
    }
}

/// The changes show ten to a page, newest first. A pager row under them moves to
/// newer and older pages. A plot switch goes back to the newest page.
struct ChangeLogSection: View {
    let review: ReviewModel
    let plot: String
    @State private var pageIndex = 0

    var body: some View {
        let page = ChangeRules.page(of: review.log(plot: plot), index: pageIndex)
        VStack(alignment: .leading, spacing: 6) {
            PanelSectionHeader(title: "Changes").accessibilityIdentifier("panel-change-log")
            if page.changes.isEmpty {
                EmptyRow(text: "No changes")
            } else {
                ChangeTimeline(review: review, changes: page.changes, diffOpen: false)
            }
            if page.count > 1 { pager(page) }
        }
        .animation(LoamAnimation.arrive, value: page.changes.map(\.id))
        .onChange(of: plot) { pageIndex = 0 }
    }

    private func pager(_ page: ChangeRules.LogPage) -> some View {
        HStack(spacing: LoamTheme.space2) {
            Text(page.range)
                .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                .monospacedDigit()
                .accessibilityIdentifier("change-log-range")
            Spacer()
            Button { pageIndex = page.index - 1 } label: { Image(systemName: "chevron.left") }
                .disabled(!page.hasNewer)
                .help("Newer changes")
                .accessibilityLabel("Newer changes")
                .accessibilityIdentifier("change-log-newer")
            Button { pageIndex = page.index + 1 } label: { Image(systemName: "chevron.right") }
                .disabled(!page.hasOlder)
                .help("Older changes")
                .accessibilityLabel("Older changes")
                .accessibilityIdentifier("change-log-older")
        }
        .padding(.horizontal, 8)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(LoamColor.inkMuted)
    }
}

/// The rows of a list of changes on one thin vertical line through the avatars.
struct ChangeTimeline: View {
    let review: ReviewModel
    let changes: [Change]
    let diffOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(changes) { change in
                ChangeRow(review: review, change: change, diffOpen: diffOpen)
                    .transition(LoamAnimation.growIn)
            }
        }
        .background(alignment: .topLeading) {
            if changes.count > 1 {
                Rectangle()
                    .fill(LoamColor.rule)
                    .frame(width: 1)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .padding(.leading, 8 + 9.5)
            }
        }
    }
}

/// One change as a timeline row (ticket 87): a round avatar of the actor, "Claude set Where it
/// stands" and a caption with the time and the source. Undo is a small text button that shows on
/// hover and on keyboard focus. An undone change dims and says when it was undone. In the log a
/// disclosure chevron opens and closes the diff. Under "New since you looked" the diff is always open.
struct ChangeRow: View {
    let review: ReviewModel
    let change: Change
    let diffOpen: Bool
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var undoFocused: Bool

    private static let avatar: CGFloat = 20

    var body: some View {
        let label = review.actorLabel(change)
        let showDiff = diffOpen || expanded
        let undone = review.undoneNote(change) != nil
        VStack(alignment: .leading, spacing: LoamTheme.space1) {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 1) {
                    headline(label)
                    Text("\(review.clock(change)) \u{00B7} \(ChangeRules.source(change.actor, paneName: label.pane?.name))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LoamColor.inkFaint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .opacity(undone ? 0.55 : 1)
                Spacer(minLength: LoamTheme.space1)
                trailing
                if !diffOpen { disclosure }
            }
            if showDiff {
                VStack(alignment: .leading, spacing: LoamTheme.space1) {
                    ForEach(Array(ChangeRules.entryViews(change).enumerated()), id: \.offset) { _, entry in
                        EntryDiffView(entry: entry)
                    }
                }
                .padding(.leading, Self.avatar + 10)
                .padding(.bottom, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("change-diff-\(diffOpen ? "new" : "log")-\(change.id)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(LoamAnimation.fast, value: hovering)
        .animation(LoamAnimation.settle, value: showDiff)
        .animation(LoamAnimation.settle, value: undone)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("change-\(diffOpen ? "new" : "log")-\(change.id)")
    }

    private var avatar: some View {
        let icon: LoamIcon = switch ChangeRules.actorGlyph(change.actor) {
        case .claude: .session
        case .person: .symbol("person")
        case .terminal: .symbol("terminal")
        }
        return LoamIconView(icon: icon, size: 11, color: LoamColor.inkMuted)
            .frame(width: Self.avatar, height: Self.avatar)
            .background(Circle().fill(LoamColor.chrome).overlay(Circle().fill(LoamColor.cardFill)))
            .overlay(Circle().strokeBorder(LoamColor.hairline))
            .accessibilityHidden(true)
    }

    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(LoamColor.inkFaint)
        .help(expanded ? "Hide the change" : "Show the change")
        .accessibilityLabel(expanded ? "Hide the change" : "Show the change")
        .accessibilityIdentifier("change-disclose-\(change.id)")
    }

    /// "Claude set Where it stands": the actor in `ink`, medium, then the rest in `ink-muted`. A session
    /// that has a pane is a button that goes to the pane.
    @ViewBuilder private func headline(_ label: ActorLabel) -> some View {
        let rest = Text(" " + ChangeRules.sentence(change)).font(.system(size: 12.5)).foregroundStyle(LoamColor.inkMuted)
        let actor = Text(ChangeRules.actorName(change.actor)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(LoamColor.ink)
        if label.pane != nil {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button { review.goToPane(of: label) } label: { actor }
                    .buttonStyle(.plain)
                    .help("Go to \(label.text)")
                    .accessibilityLabel("Go to \(label.text)")  // The button shows "Claude". The pane is in the label.
                    .accessibilityIdentifier("change-actor-\(change.id)")
                rest.lineLimit(2)
            }
        } else {
            (actor + rest)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(label.hover ?? label.text)
                .accessibilityLabel("\(label.text) \(ChangeRules.sentence(change))")
                .accessibilityIdentifier("change-actor-\(change.id)")
        }
    }

    @ViewBuilder private var trailing: some View {
        if let note = review.undoneNote(change) {
            Text(note).font(.system(size: 11.5)).foregroundStyle(LoamColor.inkFaint).monospacedDigit()
                .fixedSize()
                .accessibilityIdentifier("change-undone-\(change.id)")
        } else if ChangeRules.canUndo(change) {
            Button("Undo") { Task { await review.undo(change) } }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LoamColor.ink)
                .focused($undoFocused)
                // Hidden until the pointer or the keyboard is on the row. It stays in the accessibility tree.
                .opacity(hovering || undoFocused ? 1 : 0.001)
                .accessibilityIdentifier("change-undo-\(change.id)")
        }
    }
}

struct EntryDiffView: View {
    let entry: ChangeRules.EntryView

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            switch entry.body {
            case .words(let segments):
                Text(attributed(segments)).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
            case .added(let text):
                Text(text).loamText(LoamTheme.bodyStyle, LoamColor.moss).textSelection(.enabled)
            case .removed(let text):
                Text(text).loamText(LoamTheme.bodyStyle, LoamColor.rust).strikethrough().textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(_ segments: [WordDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            var part = AttributedString(segment.text + " ")
            switch segment.kind {
            case .same: break
            case .removed:
                part.foregroundColor = LoamColor.rust
                part.strikethroughStyle = .single
            case .added: part.foregroundColor = LoamColor.moss
            }
            out += part
        }
        return out
    }
}


/// The undo clash: the later change with its diff, then what undo writes. Cancel or "Undo and
/// overwrite". It is a callout at the top of the plot panel.
struct UndoClashSection: View {
    let review: ReviewModel
    let prompt: UndoClashPrompt

    var body: some View {
        CalloutCard {
            PanelCallout("A later change edited the same fields.", emphasis: true)
                .accessibilityIdentifier("undo-clash")
            ForEach(prompt.laterChanges) { later in
                VStack(alignment: .leading, spacing: LoamTheme.space1) {
                    Text("\(review.actorLabel(later).text) at \(review.clock(later)):")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    ForEach(Array(ChangeRules.entryViews(later).enumerated()), id: \.offset) { _, entry in
                        EntryDiffView(entry: entry)
                    }
                }
            }
            VStack(alignment: .leading, spacing: LoamTheme.space1) {
                Text("Undo would write:").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                ForEach(Array(prompt.undoWouldWrite.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChangeRules.itemTitle(entry.item)).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        Text("Now: \(entry.old ?? "(none)")").loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                        Text("After undo: \(entry.new ?? "(removed)")").loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            TrailingButtons(pill: true) {
                Button("Cancel") { review.cancelClash() }
                    .accessibilityIdentifier("undo-clash-cancel")
                Button("Undo and overwrite", role: .destructive) { Task { await review.confirmOverwrite() } }
                    .foregroundStyle(LoamColor.rust)
                    .accessibilityIdentifier("undo-clash-overwrite")
            }
        }
        .transition(LoamAnimation.growIn)
    }
}
