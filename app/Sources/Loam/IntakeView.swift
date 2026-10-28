import AppKit
import LoamKit
import SwiftUI

/// The Intake page (ticket 204): the open issues of the plot's GitHub repos and the open tickets of its maps. A click
/// on a row shows the item beside the list, with a form that starts a run from it.
struct IntakeView: View {
    let model: AppModel
    let plotID: String
    @State private var filter = Filter.all
    @State private var hideWithRun = false
    @State private var selected: String?

    /// Which source the list shows.
    enum Filter: String, CaseIterable {
        case all, linear, github, map
        var words: String {
            switch self {
            case .all: "All"
            case .linear: "Linear"
            case .github: "GitHub"
            case .map: "The map"
            }
        }
    }

    var body: some View {
        let list = model.intake?.plotID == plotID ? model.intake : nil
        let items = (list?.items ?? []).filter { item in
            (filter == .all || item.source == filter.rawValue) && !(hideWithRun && !item.runID.isEmpty)
        }
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LoamTheme.space6) {
                    header(list)
                    if let list {
                        filters(list)
                        if items.isEmpty {
                            Text(list.items.isEmpty ? "No open issues or tickets." : "No item matches.")
                                .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                                .accessibilityIdentifier("intake-empty")
                        } else {
                            table(items)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(LoamTheme.space8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let item = list?.items.first(where: { $0.id == selected }) {
                LoamColor.inkHairline.frame(width: 1)
                IntakeDetail(model: model, plotID: plotID, item: item)
                    .id(item.id)
                    .frame(width: 360)
                    .clipped()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake")
    }

    /// The name of a source kind for a person.
    static func sourceWords(_ kind: String) -> String {
        switch kind {
        case "linear": "Linear"
        case "github": "GitHub"
        default: "Map"
        }
    }

    private func header(_ list: IntakeList?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Intake").loamText(LoamTheme.plotNameStyle)
                Spacer()
                Button("Recurring and rules") { Task { await model.showRecurring(plot: plotID) } }
                    .loamSecondaryButton()
                    .help("The runs of this plot that start on a timetable, and the rules that every run must pass")
                    .accessibilityIdentifier("intake-recurring")
            }
            Text(model.plots.first { $0.id == plotID }?.name ?? "").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
            if let list {
                if list.sources.isEmpty {
                    Text("This plot has no Linear link, no GitHub repo, and no map link, so it has no intake.")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                if !list.sources.isEmpty, !list.sources.contains(where: { $0.kind == "linear" }) {
                    Text("To list Linear issues here, add the link of a Linear team or project to the plot.")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                        .accessibilityIdentifier("intake-no-linear")
                }
                ForEach(Array(list.sources.enumerated()), id: \.offset) { _, source in
                    HStack(spacing: 6) {
                        Text(IntakeView.sourceWords(source.kind)).loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                        Text(source.label).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        if !source.error.isEmpty {
                            Text(source.error).loamText(LoamTheme.captionStyle, LoamColor.rust).lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("intake-source-\(source.kind)")
                }
            }
        }
    }

    private func filters(_ list: IntakeList) -> some View {
        HStack(spacing: LoamTheme.space2) {
            // A source with no item and no link has no filter.
            ForEach(Filter.allCases.filter { f in f == .all || list.sources.contains { $0.kind == f.rawValue } }, id: \.self) { f in
                let count = f == .all ? list.items.count : list.items.filter { $0.source == f.rawValue }.count
                Button { filter = f } label: {
                    Text("\(f.words) \(count)")
                        .loamText(LoamTheme.captionStyle, filter == f ? LoamColor.ink : LoamColor.inkMuted)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(filter == f ? LoamColor.inkSelected : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(filter == f ? Color.clear : LoamColor.inkHairline))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("intake-filter-\(f.rawValue)")
            }
            Spacer()
            Toggle("Hide items with a run", isOn: $hideWithRun)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(LoamColor.inkMuted)
                .accessibilityIdentifier("intake-hide-with-run")
        }
    }

    private func table(_ items: [IntakeItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().overlay(LoamColor.inkHairline) }
                IntakeRow(item: item, run: model.runs.first { $0.id == item.runID }, selected: selected == item.id) {
                    selected = selected == item.id ? nil : item.id
                }
            }
        }
        .loamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-items")
    }
}

/// One item of the list: its key, its title, its status, and its run.
private struct IntakeRow: View {
    let item: IntakeItem
    let run: Run?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoamTheme.space3) {
                Text(item.key).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).lineLimit(1).frame(width: 76, alignment: .leading)
                Text(item.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Text(([item.status, item.priority] + item.labels).filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted).lineLimit(1)
                    .fixedSize()
                Group {
                    if let run {
                        HStack(spacing: 6) {
                            if run.state.needsYou { AttentionDot(mark: .needs).frame(width: 8, height: 8) }
                            Text(run.state.words).loamText(LoamTheme.captionStyle, LoamColor.ink).lineLimit(1)
                        }
                    } else {
                        Text("No run").loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    }
                }
                .frame(width: 104, alignment: .leading)
            }
            .padding(.horizontal, LoamTheme.space4)
            .frame(height: 40)
            .background(selected ? LoamColor.inkSelected : hovering ? LoamColor.inkFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("intake-row-\(item.key)")
    }
}

/// The item beside the list: what it is, a link to it, and the form that starts a run from it, or its run.
private struct IntakeDetail: View {
    let model: AppModel
    let plotID: String
    let item: IntakeItem
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

    init(model: AppModel, plotID: String, item: IntakeItem) {
        self.model = model
        self.plotID = plotID
        self.item = item
        _draft = State(initialValue: RunDraft(item: item))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space4) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.isTicket ? item.key : "\(IntakeView.sourceWords(item.source)) \u{00B7} \(item.key)").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    Text(item.title).loamText(LoamTheme.rowStyle).textSelection(.enabled)
                    Text(([item.status, item.priority] + item.labels).filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                Button(item.isTicket ? "Open the ticket" : "Open the issue") { open() }
                    .loamSecondaryButton()
                    .accessibilityIdentifier("intake-open")
                Text(item.source == "linear"
                     ? "The run gets the link to the issue, not a copy of its text. The issue moves to In Progress when the run starts."
                     : "The run gets the \(item.isTicket ? "path of the ticket" : "link to the issue"), not a copy of its text.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                if let run = model.runs.first(where: { $0.id == item.runID }) {
                    runCard(run)
                } else {
                    form
                }
            }
            .padding(LoamTheme.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("intake-detail")
    }

    private func runCard(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("Run").loamLabel()
            Button { Task { await model.openRun(run.id) } } label: {
                HStack {
                    Text(run.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                    Spacer()
                    Text(run.state.words).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                .padding(LoamTheme.space3)
                .loamCard()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intake-run")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            Text("Start a run").loamLabel()
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
            }
            if let bases = model.runBases, bases.plot == plotID, !bases.items.isEmpty {
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
            Stepper(value: $draft.maxTries, in: 1...8) {
                Text("\(draft.maxTries) \(draft.maxTries == 1 ? "try" : "tries")").loamText(LoamTheme.bodyStyle)
            }
            .accessibilityIdentifier("intake-tries")
            .task(id: plotID) {
                await model.readRunBases(plot: plotID)
                if draft.base == nil, let first = model.runBases?.first { draft.base = first }
            }
            if let error = model.runStartError {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                    .accessibilityIdentifier("intake-start-error")
            }
            HStack(spacing: LoamTheme.space2) {
                if model.isStartingRun { ProgressView().controlSize(.small) }
                if shaping {
                    Text("Claude is drafting the run. This takes a minute or two.")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                Spacer()
                Button("Shape with Claude") { shape() }
                    .loamSecondaryButton()
                    .disabled(model.isStartingRun || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Claude reads the issue and the repo, and drafts the goal, the checks and a plan. You approve the draft at the desk.")
                    .accessibilityIdentifier("intake-shape")
                Button(model.runStartNeedsSetupApproval ? "Approve the setup and start" : "Start run") { start() }
                    .loamPrimaryButton()
                    .disabled(model.isStartingRun || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
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

    private func start() {
        var draft = draft
        draft.checks = checks.compactMap { row in
            let command = row.command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            return RunCheck(name: name.isEmpty ? command : name, command: command)
        }
        draft.approveSetup = model.runStartNeedsSetupApproval
        Task { await model.startRun(plot: plotID, draft: draft) }
    }

    /// Claude drafts the goal and the checks, so the form gives only the title, the tries, and the issue.
    private func shape() {
        shaping = true
        Task {
            await model.shapeRun(plot: plotID, draft: draft)
            shaping = false
        }
    }

    private func open() {
        let url = item.isTicket ? URL(fileURLWithPath: item.url) : URL(string: item.url)
        if let url { NSWorkspace.shared.open(url) }
    }
}
