import LoamKit
import SwiftUI

/// The quick switcher (spec 8.8): a search field and a ranked list over the panes.
/// Styled with the Switcher component of the design system (docs/design/components/Switcher), after
/// Spotlight: a glass panel up to 680 px wide, a 22 pt field, results in sections by kind, 36 px rows with
/// an icon, a `moss-wash` selection, and matched letters in `moss`.
struct SwitcherView: View {
    let model: SwitcherModel
    @FocusState private var fieldFocused: Bool
    /// False until the panel has dropped in. Reset each time the switcher opens.
    @State private var arrived = false

    /// One column: the list alone, 680 wide at most.
    static let width: CGFloat = 680
    /// Two columns: the list and the preview, 860 wide at most.
    static let wideWidth: CGFloat = 860
    static let listWidth: CGFloat = 400
    static let listHeight: CGFloat = 420
    static let radius: CGFloat = 24
    /// The panel margin each side.
    static let margin: CGFloat = 24
    /// The preview shows when the panel can be this wide. Less room, and the switcher stays one column.
    static let previewMinWidth: CGFloat = 720

    /// True when a panel in a window `available` wide has room for the preview.
    static func showsPreview(available: CGFloat) -> Bool { available - 2 * margin >= previewMinWidth }

    var body: some View {
        GeometryReader { geometry in
            let wide = Self.showsPreview(available: geometry.size.width)
            ZStack(alignment: .top) {
                // Spotlight does not dim what is behind it. A click outside the panel closes it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.close() }
                panel(wide: wide, listHeight: min(Self.listHeight, max(180, geometry.size.height - 96 - 56 - 45 - 24)))
                    // A narrow pane area takes a narrower panel, with a margin each side.
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 96)
                    .opacity(arrived ? 1 : 0)
                    .scaleEffect(arrived || LoamMotion.reduceMotion ? 1 : 0.98, anchor: .top)
                    .offset(y: arrived || LoamMotion.reduceMotion ? 0 : -8)
            }
        }
        .task(id: model.openCount) {
            arrived = false
            withAnimation(LoamAnimation.arrive) { arrived = true }
            // The hosting view becomes first responder after this view appears.
            for _ in 0..<5 {
                fieldFocused = true
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    private func panel(wide: Bool, listHeight: CGFloat) -> some View {
        // One snapshot of the results, so no part of the panel reads an index of a newer list.
        let results = model.results
        let selected = results.indices.contains(model.selection) ? results[model.selection] : nil
        let context = model.previewContext
        let preview = selected.map { SwitcherPreview.make(for: $0.item, in: context) }
        return VStack(spacing: 0) {
            HStack(spacing: LoamTheme.space3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(LoamColor.inkMuted)
                TextField("Search plots, panes, and links, or type > for actions", text: Binding(
                    get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .foregroundStyle(LoamColor.ink)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("switcher-field")
                    .onSubmit { model.chooseSelected() }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { model.close(); return .handled }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            if !results.isEmpty || !model.query.isEmpty {
                LoamColor.rule.frame(height: 1).padding(.horizontal, 10)
                if wide {
                    HStack(spacing: 0) {
                        list(results, context: context, fixedHeight: true, height: listHeight)
                            .frame(width: Self.listWidth)
                        LoamColor.rule.frame(width: 1)
                        Group {
                            if let preview {
                                SwitcherPreviewView(preview: preview)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: listHeight)
                } else {
                    list(results, context: context, fixedHeight: false, height: listHeight)
                }
                if let selected, let preview {
                    SwitcherFooter(icon: selected.item.icon, action: preview.footerAction) { model.chooseSelected() }
                }
            }
        }
        .frame(maxWidth: wide ? Self.wideWidth : Self.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.radius))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("switcher")
    }

    private static func headingID(_ kind: SwitcherItem.Kind) -> String { "heading-\(kind.rawValue)" }

    private func list(_ results: [SwitcherResult], context: SwitcherPreview.Context, fixedHeight: Bool, height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections, id: \.kind) { section in
                        Text(section.kind.heading)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LoamColor.inkFaint)
                            .padding(.leading, 10)
                            .padding(.top, section.rows.lowerBound == 0 ? 4 : 10)
                            .padding(.bottom, 3)
                            .id(Self.headingID(section.kind))
                            .accessibilityHidden(true)
                        ForEach(section.rows.map { (index: $0, result: results[$0]) }, id: \.result.id) { entry in
                            let (index, result) = entry
                            row(result, index: index, selected: index == model.selection, context: context)
                                .id(result.id)
                                .onTapGesture { model.choose(result.item) }
                        }
                    }
                    if results.isEmpty {
                        Text("No results")
                            .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                            .frame(maxWidth: .infinity)
                            .padding(LoamTheme.space4)
                            .accessibilityIdentifier("switcher-empty")
                    }
                }
                .padding(LoamTheme.space2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: height)
            .fixedSize(horizontal: false, vertical: !fixedHeight)
            .onChange(of: model.selection) { _, selection in
                guard model.results.indices.contains(selection) else { return }
                // On the first row of a section, scroll to its heading, so the heading stays in view.
                if let section = model.sections.first(where: { $0.rows.lowerBound == selection }) {
                    proxy.scrollTo(Self.headingID(section.kind))
                } else {
                    proxy.scrollTo(model.results[selection].id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("switcher-list")
    }

    private func row(_ result: SwitcherResult, index: Int, selected: Bool, context: SwitcherPreview.Context) -> some View {
        let item = result.item
        return HStack(spacing: 12) {
            LoamIconView(icon: item.icon, size: 15, color: LoamColor.inkMuted)
                .frame(width: 20)
            title(result)
                .lineLimit(1)
                .fixedSize()
            if item.kind == .pane, item.attention != .none {
                AttentionDot(mark: item.attention == .needsYou ? .needs : .unread)
                    .frame(width: AttentionDotView.size, height: AttentionDotView.size)
            }
            if let subtitle = SwitcherPreview.subtitle(for: item, in: context) {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(LoamColor.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: LoamTheme.space2)
            if item.kind == .action, !item.shortcut.isEmpty {
                HStack(spacing: 3) { ForEach(Array(item.shortcut.enumerated()), id: \.offset) { SwitcherKeycap(text: String($1)) } }
            } else {
                Text(item.accessory)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LoamColor.inkFaint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(selected ? LoamColor.ink.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .animation(LoamAnimation.settle, value: selected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("switcher-row-\(index)")
        .accessibilityLabel(item.title)
        .accessibilityValue(spoken(item, selected: selected))
    }

    /// The text that a screen reader and the driver read: title, plot, kind, state.
    private func spoken(_ item: SwitcherItem, selected: Bool) -> String {
        var parts = [item.title]
        if let plot = item.plotName { parts.append(plot) }
        parts.append(item.kind.rawValue)
        switch item.attention {
        case .needsYou: parts.append("needs you")
        case .doneUnread: parts.append("done, unread")
        case .none: break
        }
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    /// The title with the matched letters in bold `moss`.
    private func title(_ result: SwitcherResult) -> Text {
        var attributed = AttributedString()
        for (offset, character) in result.item.title.enumerated() {
            var piece = AttributedString(String(character))
            if result.titleMatches.contains(offset) {
                piece.font = .system(size: 14, weight: .semibold)
                piece.foregroundColor = LoamColor.moss
            } else {
                piece.font = .system(size: 14, weight: .medium)
                piece.foregroundColor = LoamColor.ink
            }
            attributed.append(piece)
        }
        return Text(attributed)
    }
}
