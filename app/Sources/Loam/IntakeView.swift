import AppKit
import LoamKit
import SwiftUI

/// The Intake page (ticket 204): the open Linear issues, GitHub issues and map tickets of the plot, in a table. A click
/// on a row shows the item in the detail at the right. Check rows to shape them, or start them, all at once in the bar
/// at the bottom. "Start as a chore" in the detail opens the full start form in a sheet.
struct IntakeView: View {
    let model: AppModel
    let plotID: String
    @State private var filter = IntakeContent.Filter()
    @State private var selected: String?
    /// The IDs of the checked items.
    @State private var checked: Set<String> = []
    @State private var kind = IntakeContent.BatchKind.feature
    @State private var split = false
    /// The item of the start form sheet.
    @State private var startForm: IntakeItem?
    @State private var rules: [Rule] = []
    @State private var movesToInProgress = false

    /// The width of the detail column, with its padding.
    static let detailWidth: CGFloat = 300

    /// The list of the plot, the rows that the filter keeps, and the focused row: the selected row, else the first.
    /// The key actions call it when they run, since SwiftUI can keep the action of the render that first gave the key,
    /// before the list was read (TAS-47).
    private func current() -> (list: IntakeList?, rows: [IntakeItem], focused: IntakeItem?) {
        let list = model.intake?.plotID == plotID ? model.intake : nil
        let rows = list.map { IntakeContent.rows($0, filter: filter) } ?? []
        return (list, rows, rows.first { $0.id == selected } ?? rows.first)
    }

    var body: some View {
        let (list, rows, focused) = current()
        let checkedRows = rows.filter { checked.contains($0.id) && $0.runID.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            header(list)
            if let list {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        chips(list)
                        if rows.isEmpty {
                            Text(empty(list))
                                .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                                .padding(.top, LoamTheme.space3)
                                .accessibilityIdentifier("intake-empty")
                            Spacer(minLength: 0)
                        } else {
                            table(rows, focused: focused?.id, barShows: !checkedRows.isEmpty)
                        }
                    }
                    .padding(.leading, 20).padding(.trailing, LoamTheme.space4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .overlay(alignment: .bottom) {
                        if !checkedRows.isEmpty {
                            bar(checkedRows)
                                .padding(.leading, 20).padding(.trailing, LoamTheme.space4).padding(.bottom, LoamTheme.space4)
                        }
                    }
                    if let focused {
                        IntakeDetail(model: model, plotID: plotID, item: focused, rules: rules,
                                     movesToInProgress: movesToInProgress) { startForm = focused }
                            .id(focused.id)
                            .frame(width: Self.detailWidth)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.trailing, LoamTheme.space2).padding(.bottom, LoamTheme.space2)
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(.leading, 20)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // X checks or unchecks the selected row. ⌘↩ is on the button of the bar. ↓ and ↑, or J and K as at the desk,
            // select the next and the previous row (TAS-47).
            Group {
                Button("") { toggle(current().focused) }
                    .keyboardShortcut("x", modifiers: [])
                ForEach([(KeyEquivalent.downArrow, 1), ("j", 1), (.upArrow, -1), ("k", -1)], id: \.0.character) { key, step in
                    Button("") {
                        let (_, rows, focused) = current()
                        selected = IntakeContent.move(from: focused?.id, in: rows, by: step)
                    }
                        .keyboardShortcut(key, modifiers: [])
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(item: $startForm) { item in
            IntakeStartSheet(model: model, plotID: plotID, item: item) { startForm = nil }
        }
        .task(id: plotID) {
            rules = await model.intakeRules(plot: plotID)
            movesToInProgress = await model.linearMovesToInProgress() ?? false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake")
    }

    private func empty(_ list: IntakeList) -> String {
        if list.sources.isEmpty { return "This plot has no Linear link, no GitHub repo, and no map link, so it has no intake." }
        return list.items.isEmpty ? "No open issues or tickets." : IntakeContent.noMatchWords(list, filter: filter)
    }

    private func toggle(_ item: IntakeItem?) {
        guard let item, item.runID.isEmpty else { return }
        if checked.remove(item.id) == nil { checked.insert(item.id) }
    }

    // MARK: Header

    private func header(_ list: IntakeList?) -> some View {
        HStack(alignment: .center, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 0) {
                plotMenu()
                if let list {
                    let reads = IntakeContent.readsLine(list.sources)
                    if !reads.isEmpty {
                        Text(reads).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted).lineLimit(1)
                            .help(reads)
                            .accessibilityIdentifier("intake-reads")
                    }
                    if !list.sources.isEmpty, !list.sources.contains(where: { $0.kind == "linear" }) {
                        Text("To list Linear issues here, add the link of a Linear team or project to the plot.")
                            .font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint)
                            .accessibilityIdentifier("intake-no-linear")
                    }
                    ForEach(Array(list.sources.enumerated()).filter { !$0.element.error.isEmpty }, id: \.offset) { _, source in
                        Text("\(IntakeContent.sourceWords(source.kind)) \(source.label): \(source.error)")
                            .font(.system(size: 11)).foregroundStyle(LoamColor.rust).lineLimit(2)
                            .accessibilityIdentifier("intake-source-\(source.kind)")
                    }
                }
            }
            Spacer(minLength: LoamTheme.space3)
            Button("Recurring and rules") { Task { await model.showRecurring(plot: plotID) } }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(LoamColor.inkMuted)
                .help("The runs of this plot that start on a timetable, and the rules that every run must pass")
                .accessibilityIdentifier("intake-recurring")
            if let list { sourceSwitch(list) }
        }
        .padding(.leading, 20).padding(.trailing, LoamTheme.space3).padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    /// The title, "Intake · <plot>", is a menu of the plots (TAS-44). A choice shows the intake of that plot, and the
    /// active plot of the window stays.
    private func plotMenu() -> some View {
        let name = model.plots.first { $0.id == plotID }?.name ?? ""
        let choices = IntakeContent.plotChoices(model.plots, intake: model.todayData.intake.mapValues(\.list), now: model.now())
        return Menu {
            Picker("Plot", selection: Binding(get: { plotID }, set: { plot in Task { await model.showIntake(plot: plot) } })) {
                ForEach(choices, id: \.plotID) { Text($0.words).tag($0.plotID) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text("Intake \u{00B7} \(name)")
                    .loamText(LoamTheme.windowTitleStyle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LoamColor.inkMuted)
            }
            .contentShape(Rectangle())
        }
        // The menu draws its label as it is, as the popups of the new worktree sheet do.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show the intake of another plot")
        .accessibilityLabel("Plot")
        .accessibilityValue(name)
        .accessibilityIdentifier("intake-plot")
    }

    /// The source switch: All, then each source that the plot has.
    private func sourceSwitch(_ list: IntakeList) -> some View {
        HStack(spacing: 0) {
            ForEach(IntakeContent.sourceChoices(list), id: \.source) { choice in
                let on = filter.source == choice.source
                Button { filter.source = choice.source } label: {
                    Text(choice.words)
                        .font(.system(size: 12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? LoamColor.ink : LoamColor.inkMuted)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(on ? LoamColor.inkSelected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("intake-filter-\(choice.source.rawValue)")
            }
        }
        .padding(2)
        .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.inkHairline))
        .fixedSize()
    }

    // MARK: Chips

    private func chips(_ list: IntakeList) -> some View {
        HStack(spacing: LoamTheme.space2) {
            if IntakeContent.showsThisCycle(list) {
                chip("This cycle", on: $filter.thisCycle, id: "intake-this-cycle")
            }
            chip("Assigned to me", on: $filter.assignedToMe, id: "intake-assigned")
            chip("Hide items with a run", on: $filter.hideWithRun, id: "intake-hide-with-run")
            chip(IntakeContent.hideTakenWords(list), on: $filter.hideTaken, id: "intake-hide-taken")
                .help("Hide the items that someone else has, or that are in progress")
            let milestones = IntakeContent.milestoneChoices(list)
            if !milestones.isEmpty { milestoneMenu(list, milestones) }
            Spacer(minLength: LoamTheme.space2)
            Text(IntakeContent.sortWords).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted).lineLimit(1)
                .help(IntakeContent.sortHelp)
        }
        .frame(height: 40)
    }

    /// The Milestone menu (TAS-51), drawn as a chip that is on while it keeps one milestone.
    private func milestoneMenu(_ list: IntakeList, _ choices: [IntakeContent.MilestoneChoice]) -> some View {
        let milestone = IntakeContent.activeMilestone(list, filter: filter)
        let on = milestone != nil
        return Menu {
            Picker("Milestone", selection: Binding(get: { milestone }, set: { filter.milestone = $0 })) {
                ForEach(choices, id: \.milestone) { Text($0.words).tag($0.milestone) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(IntakeContent.milestoneWords(milestone)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12))
            .foregroundStyle(on ? LoamColor.ink : LoamColor.inkMuted)
            .padding(.horizontal, 10).frame(height: 26)
            .background(on ? LoamColor.inkSelected : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : LoamColor.rule))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only the issues of one milestone")
        .accessibilityLabel("Milestone")
        .accessibilityValue(IntakeContent.milestoneWords(milestone))
        .accessibilityIdentifier("intake-milestone")
    }

    private func chip(_ title: String, on: Binding<Bool>, id: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(on.wrappedValue ? LoamColor.ink : LoamColor.inkMuted)
                .padding(.horizontal, 10).frame(height: 26)
                .background(on.wrappedValue ? LoamColor.inkSelected : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on.wrappedValue ? Color.clear : LoamColor.rule))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    // MARK: Table

    private func table(_ rows: [IntakeItem], focused: String?, barShows: Bool) -> some View {
        // A list with no Linear priority has no Priority column.
        let priority = rows.contains { !$0.priority.isEmpty }
        return VStack(spacing: 0) {
            IntakeColumns(height: 28, showsPriority: priority) {
                Color.clear
            } id: {
                Text("ID")
            } title: {
                Text("Title")
            } source: {
                Text("Source")
            } status: {
                Text("Status")
            } priority: {
                Text("Priority")
            } run: {
                Text("Run")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(LoamColor.inkFaint)
            .overlay(alignment: .bottom) { LoamColor.rule.frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { item in
                            IntakeRow(item: item, run: model.runs.first { $0.id == item.runID }, showsPriority: priority,
                                      focused: focused == item.id,
                                      checked: Binding(get: { checked.contains(item.id) },
                                                       set: { if $0 { checked.insert(item.id) } else { checked.remove(item.id) } })) {
                                selected = item.id
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.bottom, barShows ? 80 : LoamTheme.space4)
                }
                // A key moves the selection out of view: the table scrolls the least that shows the row.
                .onChange(of: focused) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-items")
    }

    // MARK: Bar

    /// The bar of the checked rows: the kind, the shape, what the button does, and the button.
    private func bar(_ items: [IntakeItem]) -> some View {
        let shapes = IntakeContent.shapeChoices(repoCount: model.repoCheckouts[plotID]?.count ?? 0)
        let splits = kind == .feature && split && shapes.count > 1
        return HStack(spacing: LoamTheme.space3) {
            Text("\(items.count) selected").font(.system(size: 13, weight: .semibold)).fixedSize()
            LoamColor.inkHairline.frame(width: 1, height: 18)
            HStack(spacing: 6) {
                Text("Kind").font(.system(size: 12.5)).foregroundStyle(LoamColor.inkMuted).fixedSize()
                Picker("Kind", selection: $kind) {
                    ForEach(IntakeContent.BatchKind.allCases, id: \.self) { Text($0.words).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("intake-batch-kind")
            }
            if kind == .feature {
                HStack(spacing: 6) {
                    Text("Shape").font(.system(size: 12.5)).foregroundStyle(LoamColor.inkMuted).fixedSize()
                    Picker("Shape", selection: $split) {
                        ForEach(shapes, id: \.split) { Text($0.words).tag($0.split) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("intake-batch-shape")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if model.isStartingRun {
                    Text(kind == .feature ? "Claude shapes the runs, one after another. Each takes a minute or two."
                                          : "Loam starts the runs.")
                        .font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                } else {
                    Text(IntakeContent.batchCaption(count: items.count, kind: kind, split: splits))
                        .font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted).lineLimit(3)
                }
                if let error = model.runStartError {
                    Text(error).font(.system(size: 11)).foregroundStyle(LoamColor.rust).lineLimit(3).textSelection(.enabled)
                        .accessibilityIdentifier("intake-batch-error")
                }
                if let setup = model.runStartSetup { IntakeSetupCommand(setup: setup, identifier: "intake-batch-setup") }
            }
            // The caption gives way first in a narrow bar, so the labels and pickers keep their words.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            if model.isStartingRun { ProgressView().controlSize(.small) }
            Button(kind == .chore && model.runStartNeedsSetupApproval
                   ? "Approve the setup and start" : IntakeContent.batchButton(count: items.count, kind: kind)) {
                let drafts = IntakeContent.batchDrafts(items, kind: kind, split: splits)
                Task { _ = await model.startIntakeBatch(plot: plotID, drafts: drafts, shape: kind == .feature) }
            }
            .loamPrimaryButton()
            .fixedSize()
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isStartingRun)
            .accessibilityIdentifier("intake-batch-start")
        }
        .padding(.horizontal, LoamTheme.space3).padding(.vertical, 10)
        .loamFloating(.raised, ground: LoamColor.horizonB, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-batch")
    }
}

/// The columns of the table: the check box, ID, Title, Source, Status, Priority and Run.
private struct IntakeColumns<Check: View, ID: View, Title: View, Source: View, Status: View, Priority: View, RunCell: View>: View {
    var height: CGFloat
    var showsPriority: Bool
    @ViewBuilder var check: Check
    @ViewBuilder var id: ID
    @ViewBuilder var title: Title
    @ViewBuilder var source: Source
    @ViewBuilder var status: Status
    @ViewBuilder var priority: Priority
    @ViewBuilder var run: RunCell

    var body: some View {
        HStack(spacing: 10) {
            check.frame(width: 18, alignment: .leading)
            id.frame(width: 72, alignment: .leading)
            title.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            source.frame(width: 58, alignment: .leading)
            status.frame(width: 92, alignment: .leading)
            if showsPriority { priority.frame(width: 56, alignment: .leading) }
            run.frame(width: 132, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: height)
    }
}

/// The badge of a source: Linear, GitHub or Map, in a small box.
struct IntakeSourceBadge: View {
    let source: String
    var body: some View {
        Text(IntakeContent.sourceWords(source))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LoamColor.inkMuted)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: LoamTheme.radiusXs).strokeBorder(LoamColor.rule))
            .fixedSize()
    }
}

/// The mark and the words of the station of a run, such as "Run, try 2 of 3".
struct IntakeRunCell: View {
    let run: Run?
    var body: some View {
        let words = IntakeContent.runWords(run)
        HStack(spacing: 6) {
            switch words.mark {
            case .needsYou: AttentionDot(mark: .needs).frame(width: 8, height: 8)
            case .ready: Circle().strokeBorder(LoamColor.doneUnread, lineWidth: 1.5).frame(width: 8, height: 8)
            case .none: EmptyView()
            }
            Text(words.words).lineLimit(1)
        }
    }
}

/// One item of the table. A click shows it in the detail. An item with no run has a check box.
private struct IntakeRow: View {
    let item: IntakeItem
    let run: Run?
    let showsPriority: Bool
    let focused: Bool
    @Binding var checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let hasRun = !item.runID.isEmpty
        ZStack(alignment: .leading) {
            Button(action: action) {
                IntakeColumns(height: 36, showsPriority: showsPriority) {
                    Color.clear
                } id: {
                    Text(item.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(LoamColor.inkMuted)
                } title: {
                    Text(item.title).foregroundStyle(hasRun ? LoamColor.inkMuted : LoamColor.ink)
                } source: {
                    IntakeSourceBadge(source: item.source)
                } status: {
                    Text(IntakeContent.statusWords(item)).foregroundStyle(LoamColor.inkMuted)
                } priority: {
                    Text(IntakeContent.priorityWords(item)).foregroundStyle(LoamColor.inkMuted)
                } run: {
                    IntakeRunCell(run: run).foregroundStyle(LoamColor.inkMuted)
                }
                .font(.system(size: 12.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(focused ? .isSelected : [])
            .accessibilityIdentifier("intake-row-\(item.key)")
            if !hasRun {
                Toggle("Check \(item.key)", isOn: $checked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .tint(LoamColor.moss)
                    .padding(.leading, 10)
                    .accessibilityIdentifier("intake-check-\(item.key)")
            }
        }
        .background(focused || checked ? LoamColor.inkSelected : hovering ? LoamColor.inkFill : Color.clear)
        .overlay(alignment: .leading) { if focused { LoamColor.moss.frame(width: 2) } }
        .overlay(alignment: .bottom) { LoamColor.inkHairline.frame(height: 1) }
        .onHover { hovering = $0 }
    }
}

/// The item beside the table: its source, its text, what a shape of it makes, what Claude reads first, and its run.
private struct IntakeDetail: View {
    let model: AppModel
    let plotID: String
    let item: IntakeItem
    let rules: [Rule]
    let movesToInProgress: Bool
    let startAsChore: () -> Void

    var body: some View {
        let run = model.runs.first { $0.id == item.runID }
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: LoamTheme.space2) {
                        HStack(spacing: LoamTheme.space2) {
                            IntakeSourceBadge(source: item.source)
                            Text(item.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(LoamColor.inkMuted)
                            Spacer(minLength: LoamTheme.space2)
                            Text(IntakeContent.statusLine(item)).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                                .lineLimit(1)
                        }
                        Text(item.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("intake-detail-title")
                        let facts = IntakeContent.detailFacts(item)
                        if !facts.isEmpty {
                            Text(facts).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("intake-detail-facts")
                        }
                    }
                    VStack(alignment: .leading, spacing: LoamTheme.space2) {
                        if !item.text.isEmpty {
                            // All of the text, since the detail scrolls. A line limit clips the text only until a click
                            // starts a selection, which draws every line over the caption below (TAS-48).
                            Text(item.text).font(.system(size: 12.5)).foregroundStyle(LoamColor.inkMuted).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("intake-text")
                        }
                        Text(IntakeContent.fromWords(item)).font(.system(size: 11)).foregroundStyle(LoamColor.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, LoamTheme.space3).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
                    if let run {
                        runCard(run)
                    } else {
                        whenYouShapeIt
                    }
                    if !rules.isEmpty {
                        section("Claude reads first") {
                            ForEach(rules) { rule in
                                HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                                    Text("Rule: \(rule.name)").lineLimit(1)
                                    Spacer(minLength: LoamTheme.space2)
                                    Text("check").foregroundStyle(LoamColor.inkMuted)
                                }
                                .font(.system(size: 12))
                                .help(rule.command)
                            }
                        }
                        .accessibilityIdentifier("intake-reads-first")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            HStack(spacing: LoamTheme.space2) {
                Button { open() } label: {
                    Text(IntakeContent.openWords(item)).frame(maxWidth: .infinity)
                }
                .loamSecondaryButton()
                .accessibilityIdentifier("intake-open")
                if run == nil {
                    Button(action: startAsChore) {
                        Text("Start as a chore").frame(maxWidth: .infinity)
                    }
                    .loamSecondaryButton()
                    .help("The full start form: the goal, the checks, the repo, the base, the model and the tries")
                    .accessibilityIdentifier("intake-chore")
                }
            }
        }
        .padding(.horizontal, LoamTheme.space4).padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoamColor.horizonA, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LoamColor.inkHairline))
        .task(id: item.id) { await model.readRunBases(plot: plotID, repo: item.repo.isEmpty ? nil : item.repo) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-detail")
    }

    /// What a shape of the item makes: the worktree and its branch, the base, the kind, and the Linear update.
    private var whenYouShapeIt: some View {
        let taken = Set((model.worktrees[plotID] ?? []).map(\.worktree.name))
        let name = RunWorktreeName.name(title: item.title, key: item.key, taken: taken)
        let bases = model.runBases?.plot == plotID ? model.runBases : nil
        return section("When you shape it") {
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 7) {
                row("Worktree") { code(name) }
                row("Branch") {
                    VStack(alignment: .leading, spacing: 0) {
                        code(name)
                        if !item.branch.isEmpty {
                            Text("Linear's branch name is \(item.branch)").font(.system(size: 11))
                                .foregroundStyle(LoamColor.inkMuted).textSelection(.enabled)
                        }
                    }
                }
                if let base = bases?.items.first?.title {
                    row("From") { code(base) }
                }
                row("Kind") { Text("Feature. Claude drafts the goal and checks, and you approve.") }
                if item.source == "linear", movesToInProgress {
                    row("Linear") { Text("Moves to In Progress when the run starts") }
                }
            }
            .font(.system(size: 12))
        }
        .accessibilityIdentifier("intake-when-shaped")
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(LoamColor.inkMuted).frame(width: 68, alignment: .leading)
            value().fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(LoamColor.inkFaint)
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func runCard(_ run: Run) -> some View {
        section("Run") {
            Button { Task { await model.openRun(run.id) } } label: {
                HStack {
                    Text(run.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                    Spacer()
                    IntakeRunCell(run: run).font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
                }
                .padding(LoamTheme.space3)
                .loamCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intake-run")
        }
    }

    private func open() {
        let url = item.isTicket ? URL(fileURLWithPath: item.url) : URL(string: item.url)
        if let url { NSWorkspace.shared.open(url) }
    }
}

/// The full start form of one item, in a sheet: the title, the goal, the checks, the repo or the split, the base, the
/// model, the effort and the tries. Start run starts it as it is. Shape with Claude has Claude draft the goal and the
/// checks first.
private struct IntakeStartSheet: View {
    let model: AppModel
    let plotID: String
    let item: IntakeItem
    let close: () -> Void
    @State private var draft: RunDraft
    @State private var checks: [CheckRow] = [CheckRow()]
    /// Shape with Claude waits for the draft.
    @State private var shaping = false

    /// One editable check. The ID keeps each row's fields when a row above goes.
    struct CheckRow: Identifiable {
        let id = UUID()
        var name = ""
        var command = ""
    }

    init(model: AppModel, plotID: String, item: IntakeItem, close: @escaping () -> Void) {
        self.model = model
        self.plotID = plotID
        self.item = item
        self.close = close
        _draft = State(initialValue: RunDraft(item: item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start as a chore").loamText(LoamTheme.windowTitleStyle)
                Text("\(IntakeContent.sourceWords(item.source)) \(item.key). The run starts now, with the goal and the checks that you give.")
                    .font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
            }
            form
            footer
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(width: 480)
        .background(LoamColor.horizonA)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-start-sheet")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            field("Title", text: $draft.title, id: "intake-title")
            VStack(alignment: .leading, spacing: 4) {
                Text("Goal").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                TextField("What done looks like", text: $draft.goal, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...6)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .loamFieldBox()
                    .accessibilityIdentifier("intake-goal")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Done when").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                ForEach($checks) { $check in
                    let index = checks.firstIndex { $0.id == check.id } ?? 0
                    HStack(spacing: 6) {
                        TextField("Name", text: $check.name)
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                            .padding(.horizontal, 8).frame(width: 90, height: 26).loamFieldBox()
                            .accessibilityIdentifier("intake-check-name-\(index)")
                        TextField("Command, such as go test ./...", text: $check.command)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8).frame(height: 26).loamFieldBox()
                            .accessibilityIdentifier("intake-check-command-\(index)")
                        Button { checks.removeAll { $0.id == check.id } } label: {
                            Image(systemName: "minus.circle").foregroundStyle(LoamColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove the check")
                    }
                }
                Button("Add a check") { checks.append(CheckRow()) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LoamColor.inkMuted)
                    .accessibilityIdentifier("intake-add-check")
                Text("Each check is a shell command that passes when it exits 0 in the worktree. The run is done when all pass and the work is committed.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let repos = RunChoices.repos(model.repoCheckouts[plotID] ?? [])
            HStack(alignment: .top, spacing: LoamTheme.space3) {
                if repos.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repo").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        Picker("Repo", selection: $draft.repoChoice) {
                            ForEach(repos) { Text($0.title).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("The repo that the run works in. Claude can split an issue that touches more than one repo into one run for each.")
                        .accessibilityIdentifier("intake-repo")
                    }
                    .task(id: draft.repoChoice) { await readBases() }
                }
                if !draft.split, let bases = model.runBases, bases.plot == plotID, bases.repo == draft.repo, !bases.items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        Picker("Base", selection: $draft.base) {
                            ForEach(bases.items, id: \.title) { item in
                                Text(item.title).font(.system(size: 12, design: .monospaced)).tag(item.value)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("The branch that the worktree of the run starts from")
                        .accessibilityIdentifier("intake-base")
                    }
                }
            }
            ModelEffortPickers(model: $draft.model, effort: $draft.effort,
                               defaults: model.runDefaults?.plotID == plotID ? model.runDefaults : nil, id: "intake")
            Stepper(value: $draft.maxTries, in: 1...8) {
                Text("\(draft.maxTries) \(draft.maxTries == 1 ? "try" : "tries")").loamText(LoamTheme.bodyStyle)
            }
            .accessibilityIdentifier("intake-tries")
            .task(id: plotID) {
                await model.readRunDefaults(plot: plotID)
                if draft.repo == nil, !draft.split { draft.repo = model.repoCheckouts[plotID]?.first(where: \.isMain)?.id }
                await readBases()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            if let error = model.runStartError {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("intake-start-error")
            }
            if let setup = model.runStartSetup { IntakeSetupCommand(setup: setup, identifier: "intake-start-setup") }
            if shaping {
                Text("Claude is drafting the run. This takes a minute or two.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            } else if draft.split {
                Text("Claude drafts one run for each repo that the issue touches.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            HStack(spacing: LoamTheme.space2) {
                if model.isStartingRun { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close)
                    .loamSecondaryButton()
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("intake-start-cancel")
                Button("Shape with Claude") { shape() }
                    .loamSecondaryButton()
                    .disabled(model.isStartingRun || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Claude reads the issue and the repo, and drafts the goal, the checks and a plan. You approve the draft at the desk.")
                    .accessibilityIdentifier("intake-shape")
                Button(model.runStartNeedsSetupApproval ? "Approve the setup and start" : "Start run") { start() }
                    .loamPrimaryButton()
                    .disabled(model.isStartingRun || draft.split || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(draft.split ? "Only Claude can split a run across the repos. Use Shape with Claude." : "")
                    .accessibilityIdentifier("intake-start")
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            TextField(label, text: text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 9).frame(height: 28)
                .loamFieldBox()
                .accessibilityIdentifier(id)
        }
    }

    /// Reads the bases of the chosen repo, and starts the Base picker on its first base. A split has no base:
    /// each run starts from the default branch of its repo.
    private func readBases() async {
        if draft.split { draft.base = nil }
        guard !draft.split, let repo = draft.repo else { return }
        await model.readRunBases(plot: plotID, repo: repo)
        if model.runBases?.repo == draft.repo { draft.base = model.runBases?.first }
    }

    private func start() {
        var draft = draft
        draft.checks = checks.compactMap { row in
            let command = row.command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            return RunCheck(name: name.isEmpty ? command : name, command: command)
        }
        Task { if await model.startRun(plot: plotID, draft: draft) { close() } }
    }

    /// Claude drafts the goal and the checks, so the form gives only the title, the tries, and the issue.
    private func shape() {
        shaping = true
        Task {
            let shaped = await model.shapeRun(plot: plotID, draft: draft)
            shaping = false
            if shaped { close() }
        }
    }
}

/// The setup command that the next start approves, in full, since the approval names this text.
private struct IntakeSetupCommand: View {
    let setup: ShownSetup
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You approve this setup command for its repo:").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Text(setup.command).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
