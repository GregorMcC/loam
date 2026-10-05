import AppKit
import LoamKit
import SwiftUI

/// The plot sidebar (spec 8.1). It renders `SidebarModel` and calls `AppModel` for every action.
/// Ticket 71: a native sidebar tree on the system's glass sidebar. A plot holds its main checkout and
/// its worktrees, and each of those holds its panes (`SidebarModel.tree(of:)`). A tab of 2 or more
/// panes groups them under a tab row (ticket 75). The list gives the indentation, the disclosure
/// arrows, the selection highlight and the row height. The selected row is where you are: the
/// focused pane, else the active plot.
struct SidebarView: View {
    let model: AppModel
    /// The "Archived" list starts collapsed (spec 8.1).
    @State private var archivedOpen = false
    @State private var disclosure = SidebarDisclosure()

    var body: some View {
        let sidebar = model.sidebar
        VStack(spacing: 0) {
            SidebarTop(model: model, sidebar: sidebar)
            tree(sidebar)
        }
    }

    private func tree(_ sidebar: SidebarModel) -> some View {
        // No native selection: the selected row draws its own neutral fill (`rowFill`).
        List {
            if let block = model.launchBlock {
                Text(block)
                    .loamText(LoamTheme.bodyStyle, LoamColor.rust)
                    .accessibilityIdentifier("launch-block")
            }
            if !model.setupSteps.isEmpty {
                setupBanner(model.setupSteps)
            }
            Section {
                ForEach(sidebar.withPanes) { plotNode($0, sidebar) }
            } header: {
                HStack {
                    SectionLabel(text: "Plots")
                    Spacer(minLength: 0)
                    Button { NSApp.sendAction(#selector(MainWindowController.newPlot(_:)), to: nil, from: nil) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LoamColor.inkMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The same top inset as the label, so the two centre on one line.
                    .padding(.top, 10)
                    .help("New plot")
                    .accessibilityLabel("New plot")
                    .accessibilityIdentifier("new-plot-button")
                }
            }
            if !sidebar.noPanes.isEmpty {
                Section {
                    ForEach(sidebar.noPanes) { plotNode($0, sidebar) }
                } header: { SectionLabel(text: "No panes") }
            }
            if !model.archivedPlots.isEmpty {
                Section(isExpanded: $archivedOpen) {
                    ForEach(model.archivedPlots) { ArchivedRowView(plot: $0, model: model) }
                } header: {
                    HStack(spacing: LoamTheme.space1) {
                        SectionLabel(text: "Archived")
                        CountChip(text: "\(model.archivedPlots.count)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("archived-header")
                }
            }
            if let error = model.lastError {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust)
            }
        }
        .listStyle(.sidebar)
        // No ground of its own: the system's glass sidebar shows through (ticket 68).
        .scrollContentBackground(.hidden)
        .onChange(of: sidebar.activePlotID, initial: true) { _, plot in disclosure.activePlotChanged(to: plot) }
        // A focus change that lands in a closed checkout or tab opens it, so the selected row shows.
        .onChange(of: sidebar.selection) { _, selected in
            guard case .pane(let pane) = selected else { return }
            if let checkout = sidebar.checkout(holding: pane) { disclosure.setCheckout(checkout.id, open: true) }
            if let tab = sidebar.tab(holding: pane) { disclosure.setTab(tab.id, open: true) }
        }
        // The main checkout labels: again when the plot list moves or a repo changes.
        .task(id: MainCheckoutKey(plots: model.plots.map(\.id), lastRepoChange: model.review.lastRepoChangeID)) {
            guard model.launchBlock == nil else { return }
            await model.reloadMainCheckouts()
        }
    }

    /// A click on a row. Selecting a plot makes it active. Selecting a pane goes to it.
    private func select(_ row: SidebarModel.RowID) {
        switch row {
        case .plot(let plot): model.activate(plot: plot)
        case .pane(let pane): model.goToPane(pane)
        }
    }

    /// The neutral fill of the selected row: the ink at about 9%, radius 7. Nil for any other row.
    private func rowFill(_ row: SidebarModel.RowID, _ sidebar: SidebarModel) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(sidebar.selection == row ? LoamColor.inkSelected : Color.clear)
            // Inset to line up with the search field above the list.
            .padding(.horizontal, 8)
    }

    /// A plot, then its tree when it is open. A plot with nothing under it is a plain row.
    @ViewBuilder
    private func plotNode(_ row: SidebarModel.PlotRow, _ sidebar: SidebarModel) -> some View {
        let tree = sidebar.tree(of: row.id)
        let id = SidebarModel.RowID.plot(row.id)
        if tree.isEmpty {
            selectable(PlotRowView(row: row, model: model, selected: sidebar.selection == id), id, sidebar)
                .listRowBackground(rowFill(id, sidebar))
        } else {
            DisclosureGroup(isExpanded: plotOpen(row.id)) {
                ForEach(tree.items) { itemNode($0, sidebar) }
                ForEach(tree.checkouts) { checkoutNode($0, sidebar) }
            } label: {
                selectable(PlotRowView(row: row, model: model, selected: sidebar.selection == id), id, sidebar)
            }
            .listRowBackground(rowFill(id, sidebar))
        }
    }

    /// A repo row, then its panes and its worktrees when it is open (ticket 92). A worktree row that
    /// sits right under the plot, because its repo has no row, shows the same way.
    @ViewBuilder
    private func checkoutNode(_ checkout: SidebarModel.CheckoutRow, _ sidebar: SidebarModel) -> some View {
        if checkout.panes.isEmpty && checkout.worktrees.isEmpty {
            CheckoutRowView(row: checkout, model: model, open: false)
        } else {
            DisclosureGroup(isExpanded: checkoutOpen(checkout.id)) {
                ForEach(checkout.items) { itemNode($0, sidebar) }
                ForEach(checkout.worktrees) { worktreeNode($0, sidebar) }
            } label: {
                CheckoutRowView(row: checkout, model: model, open: disclosure.isOpen(checkout: checkout.id))
            }
        }
    }

    /// A worktree under its repo row, then its panes when it is open. It is not `checkoutNode`
    /// itself, because an opaque view type cannot recurse.
    @ViewBuilder
    private func worktreeNode(_ worktree: SidebarModel.CheckoutRow, _ sidebar: SidebarModel) -> some View {
        if worktree.panes.isEmpty {
            CheckoutRowView(row: worktree, model: model, open: false)
        } else {
            DisclosureGroup(isExpanded: checkoutOpen(worktree.id)) {
                ForEach(worktree.items) { itemNode($0, sidebar) }
            } label: {
                CheckoutRowView(row: worktree, model: model, open: disclosure.isOpen(checkout: worktree.id))
            }
        }
    }

    /// A pane, or a split tab and then its panes when it is open.
    @ViewBuilder
    private func itemNode(_ item: SidebarModel.TreeItem, _ sidebar: SidebarModel) -> some View {
        switch item {
        case .pane(let pane):
            paneNode(pane, sidebar)
        case .tab(let tab):
            DisclosureGroup(isExpanded: tabOpen(tab.id)) {
                ForEach(tab.panes) { paneNode($0, sidebar) }
            } label: {
                TabRowView(row: tab, model: model, open: disclosure.isOpen(tab: tab.id))
            }
        }
    }

    private func paneNode(_ pane: SidebarModel.PaneRow, _ sidebar: SidebarModel) -> some View {
        let id = SidebarModel.RowID.pane(pane.id)
        return selectable(PaneRowView(row: pane), id, sidebar)
            .listRowBackground(rowFill(id, sidebar))
    }

    /// A row that a click selects. The list has no native selection (ticket 86), so the row tells
    /// VoiceOver that it is a button and whether it is selected.
    private func selectable(_ row: some View, _ id: SidebarModel.RowID, _ sidebar: SidebarModel) -> some View {
        row
            .onTapGesture { select(id) }
            .accessibilityAction { select(id) }
            .accessibilityAddTraits(sidebar.selection == id ? [.isButton, .isSelected] : .isButton)
    }

    private func plotOpen(_ plot: String) -> Binding<Bool> {
        Binding(get: { disclosure.isOpen(plot: plot) }, set: { disclosure.setPlot(plot, open: $0) })
    }

    private func checkoutOpen(_ checkout: String) -> Binding<Bool> {
        Binding(get: { disclosure.isOpen(checkout: checkout) }, set: { disclosure.setCheckout(checkout, open: $0) })
    }

    private func tabOpen(_ tab: UUID) -> Binding<Bool> {
        Binding(get: { disclosure.isOpen(tab: tab) }, set: { disclosure.setTab(tab, open: $0) })
    }

    private func setupBanner(_ steps: [SetupStep]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Setup is not finished. Run: loam setup")
                .loamText(LoamTheme.captionStyle)
            ForEach(steps, id: \.id) { step in
                Text(step.detail.map { "\(step.id): \($0)" } ?? step.id)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
        }
        .padding(LoamTheme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loamCard(LoamColor.horizonB)
        .accessibilityIdentifier("setup-banner")
    }
}

/// What makes the sidebar read the main checkouts again.
private struct MainCheckoutKey: Equatable {
    var plots: [String]
    var lastRepoChange: Int?
}

/// One row of the tree: the icon of its level, the name, and the marks at the trailing edge.
/// Icons are medium weight in `ink-muted` (docs/design, Iconography). A session pane has the Claude mark.
private struct TreeRow<Trailing: View>: View {
    let icon: LoamIcon
    var symbolColor = LoamColor.inkMuted
    let title: String
    /// A row that is not selected is `ink-muted`. The selected row is `ink` (ticket 86).
    var titleColor = LoamColor.inkMuted
    /// The plot level is semibold, so the levels read apart.
    var bold = false
    var truncation: Text.TruncationMode = .tail
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: LoamTheme.space2) {
            LoamIconView(icon: icon, size: 12, color: symbolColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
                .font(Font(bold ? NSFont.systemFont(ofSize: LoamTheme.rowStyle.size, weight: .semibold)
                                : LoamTheme.font(LoamTheme.rowStyle)))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(truncation)
                // The name fills the row (flex: 1 in docs/design), so the marks sit at the trailing edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .frame(minHeight: 26)  // With the list's own padding, a row is about 30 pt.
        .contentShape(Rectangle())
    }
}

/// A section label: sentence case, 12 pt, medium, `ink-faint`, with room above it (ticket 86).
private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LoamColor.inkFaint)
            .textCase(nil)
            .padding(.top, 10)
    }
}

/// One plot: its symbol (`moss` for the active plot), the name, and the trailing marks
/// (docs/design/components/PlotRow). Drag it onto another plot to reorder.
private struct PlotRowView: View {
    let row: SidebarModel.PlotRow
    let model: AppModel
    let selected: Bool

    var body: some View {
        TreeRow(icon: .plot, symbolColor: row.isActive ? LoamColor.moss : LoamColor.inkMuted,
                title: row.name, titleColor: selected ? LoamColor.ink : LoamColor.inkMuted, bold: true) {
            // The attention mark: the count of panes that need you, else a blue ring for done,
            // unread, else nothing. The row combines its children for accessibility, so each mark
            // carries its words.
            if row.needsYouCount > 0 {
                NeedsYouBadge(count: row.needsYouCount, isArriving: row.isArriving)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Needs you: \(row.needsYouCount)")
            } else if row.hasDoneUnread {
                PaneMark(attention: .doneUnread)
                    .frame(width: AttentionDotView.size, height: AttentionDotView.size)
            }
            if row.newChangeCount > 0 {
                Text("\u{270E} \(row.newChangeCount)")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityIdentifier("plot-new-changes-\(row.id)")
            }
            if let number = row.number {
                Text("\u{2303}\(number)")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    .fixedSize()
            }
        }
        .draggable(row.id)
        .dropDestination(for: String.self) { items, _ in
            guard let moving = items.first else { return false }
            Task { await model.movePlot(moving, onto: row.id) }
            return true
        }
        .contextMenu {
            // Ticket 93: a session in the plot folder, not in a repo.
            Button("New session") { model.openPlotSession(row.id) }
            Button("New worktree\u{2026}") { WorktreeDialogs.askNewWorktree(plot: row.id, model: model) }
            Divider()
            Button("Archive") { PlotDialogs.askArchive(row.id, model: model) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plot-\(row.id)")
    }
}

/// A repo of the plot (`arrow.triangle.branch`) or a worktree (`arrow.triangle.pull`), named by its
/// branch. In a plot with more than one repo, a repo row shows its folder and then its branch
/// (ticket 76). A worktree shows a mark for work that removal would lose. A closed row counts its
/// panes. A click shows its pane, or opens a session when it has none.
private struct CheckoutRowView: View {
    let row: SidebarModel.CheckoutRow
    let model: AppModel
    /// The row shows its panes, so it needs no count.
    let open: Bool

    private var missing: Bool { row.worktree?.missing ?? false }

    var body: some View {
        TreeRow(icon: .symbol(row.kind == .worktree ? "arrow.triangle.pull" : "arrow.triangle.branch"),
                title: row.label, titleColor: missing ? LoamColor.inkFaint : LoamColor.inkMuted, truncation: .middle) {
            if let detail = row.detail {
                Text(detail)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if missing {
                Text("gone").loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
            } else if let worktree = row.worktree, worktree.changed > 0 || worktree.unpushed > 0 {
                Text("\u{270E}").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            if !open, !row.panes.isEmpty {
                CountChip(text: "\(row.panes.count)")
            }
        }
        .onTapGesture { show() }
        .contextMenu {
            Button("New pane") { newPane() }
            if row.kind == .worktree {
                Button("Remove\u{2026}") { WorktreeDialogs.askRemove(row.id, model: model) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction { show() }
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch row.kind {
        case .main: "main-checkout-\(row.plotID)"
        case .repo: "repo-checkout-\(row.repo?.id ?? row.id)"
        case .worktree: "worktree-\(row.id)"
        }
    }

    private func show() {
        if let pane = row.panes.first { return model.goToPane(pane.id) }
        newPane()
    }

    /// A seeded session in the checkout: `loam start`, `loam start --repo` for another repo, or
    /// `loam start --worktree` for a worktree.
    private func newPane() {
        switch row.kind {
        case .main:
            if model.workspace.activePlotID != row.plotID { model.activate(plot: row.plotID) }
            model.openTab(.session)
        case .repo:
            if model.workspace.activePlotID != row.plotID { model.activate(plot: row.plotID) }
            model.openTab(.session, repo: row.repo?.path)
        case .worktree:
            if let worktree = model.worktreeStatus(row.id)?.worktree { model.openWorktreePane(worktree) }
        }
    }
}

/// A tab of 2 or more panes (`rectangle.split.2x1`), named by its focused pane as the tab bar names it.
/// It shows the strongest mark of its panes. A closed row counts its panes. A click goes to the pane
/// that names it.
private struct TabRowView: View {
    let row: SidebarModel.TabRow
    let model: AppModel
    /// The row shows its panes, so it needs no count.
    let open: Bool

    var body: some View {
        TreeRow(icon: .symbol("rectangle.split.2x1"), title: row.title, titleColor: row.holdsFocus ? LoamColor.ink : LoamColor.inkMuted) {
            if !open {
                CountChip(text: "\(row.panes.count)")
            }
            PaneMark(attention: row.attention, isArriving: row.isArriving, paneFocused: row.needsYouFocused)
                .frame(width: AttentionDotView.size, height: AttentionDotView.size)
        }
        .onTapGesture { model.goToPane(row.lead) }
        .accessibilityElement(children: .combine)
        .accessibilityAction { model.goToPane(row.lead) }
        .accessibilityIdentifier("tab-row-\(row.id.uuidString)")
    }
}

/// The mark of one pane: a filled amber dot for Needs you, a blue ring for Done, unread, or an
/// empty slot. A running session shows no mark (docs/design, principle 2).
private struct PaneMark: View {
    let attention: PaneAttention
    var isArriving = false
    var paneFocused = false

    var body: some View {
        switch attention {
        case .needsYou:
            AttentionDot(mark: .needs, isArriving: isArriving, paneFocused: paneFocused)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Needs you")  // The words for VoiceOver and the driver.
        case .doneUnread:
            AttentionDot(mark: .unread)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Done, unread")
        case .none:
            Color.clear.accessibilityHidden(true)
        }
    }
}

/// One pane, with its title and its attention mark at the trailing edge. The list selects the
/// focused pane. Selecting another pane goes to it.
private struct PaneRowView: View {
    let row: SidebarModel.PaneRow

    var body: some View {
        TreeRow(icon: row.icon, title: row.title, titleColor: titleColor) {
            PaneMark(attention: row.attention, isArriving: row.isArriving, paneFocused: row.isFocused)
                .frame(width: AttentionDotView.size, height: AttentionDotView.size)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pane-row-\(row.id.uuidString)")
    }

    private var titleColor: Color {
        if row.state == .ended { return LoamColor.inkFaint }
        return row.isFocused ? LoamColor.ink : LoamColor.inkMuted
    }
}

/// The top of the sidebar (ticket 86), under the window buttons: a search button that looks like a
/// field, then two fixed attention rows. A click on an attention row goes to the next pane in that
/// state, across plots. With a count of 0 the row shows no count and does nothing.
private struct SidebarTop: View {
    let model: AppModel
    let sidebar: SidebarModel

    var body: some View {
        VStack(spacing: 0) {
            Button { model.switcher.open() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium))
                    Text("Search").font(.system(size: 13))
                    Spacer(minLength: 0)
                    // The real key of the switcher, one keycap per symbol.
                    ForEach(Array((LoamKeys.chord(for: .quickSwitcher)?.description ?? "").enumerated()), id: \.offset) {
                        Keycap(text: String($0.element))
                    }
                }
                .foregroundStyle(LoamColor.inkFaint)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .frame(height: 32)
                .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.inkHairline))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("sidebar-search")
            VStack(spacing: 1) {
                AttentionRow(title: "Needs you", count: sidebar.needsYouCount, id: "attention-needs-you",
                             action: { model.goToNextPane(in: .needsYou) }) {
                    AttentionDot(mark: .needs).frame(width: 8, height: 8)
                } trailing: {
                    NeedsYouCountBadge(count: sidebar.needsYouCount)
                }
                AttentionRow(title: "Done, unread", count: sidebar.doneUnreadCount, id: "attention-done-unread",
                             action: { model.goToNextPane(in: .doneUnread) }) {
                    AttentionDot(mark: .unread).frame(width: 8, height: 8)
                } trailing: {
                    Text("\(sidebar.doneUnreadCount)")
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(LoamColor.inkFaint)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

/// A fixed row: the mark, the title, and the count. It is a button only while the count is above 0.
private struct AttentionRow<Mark: View, Trailing: View>: View {
    let title: String
    let count: Int
    let id: String
    let action: () -> Void
    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoamTheme.space2) {
                mark().frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LoamColor.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 0 { trailing() }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering && count > 0 ? LoamColor.inkFill : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? "\(title): \(count)" : title)
        .accessibilityIdentifier(id)
    }
}

/// The count on the "Needs you" row: `needs-you` text on `needs-you-wash`, a pill.
private struct NeedsYouCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(LoamColor.needsYou)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(LoamColor.needsYouWash, in: Capsule())
            .fixedSize()
    }
}

/// One archived plot, muted. The menu unarchives it or deletes it.
private struct ArchivedRowView: View {
    let plot: PlotSummary
    let model: AppModel

    var body: some View {
        TreeRow(icon: .symbol("archivebox"), symbolColor: LoamColor.inkFaint, title: plot.name, titleColor: LoamColor.inkFaint) {
            EmptyView()
        }
        .contextMenu {
            Button("Unarchive") { Task { await model.unarchivePlot(plot.id) } }
            Divider()
            Button("Delete\u{2026}") { PlotDialogs.askDelete(plot, model: model) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archived-plot-\(plot.id)")
    }
}
