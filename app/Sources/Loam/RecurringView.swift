import LoamKit
import SwiftUI

/// The Recurring page of a plot (ticket 208): the runs that start on a timetable when their precheck finds work, a
/// form that adds one, and the launchd agent that starts them while the app is closed. Between the list and the form,
/// the rules of the plot (ticket 209).
struct RecurringView: View {
    let model: AppModel
    let plotID: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space6) {
                header
                agent
                if model.recurring.isEmpty {
                    Text("This plot has no recurring run yet.")
                        .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                        .accessibilityIdentifier("recurring-empty")
                } else {
                    VStack(alignment: .leading, spacing: LoamTheme.space2) {
                        ForEach(model.recurring) { RecurringCard(model: model, item: $0) }
                    }
                }
                Divider()
                RecurringForm(model: model, plotID: plotID)
                    .id(plotID)
                Divider()
                RunDefaultsSection(model: model, plotID: plotID)
                    .id(plotID)
                Divider()
                RulesSection(model: model)
                    .id(plotID)
            }
            .padding(LoamTheme.space8)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recurring")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RecurringWords.pageTitle(plot: model.plots.first { $0.id == plotID }?.name ?? ""))
                .loamText(LoamTheme.rowStyle)
            Text("A recurring run starts on a timetable when its precheck finds work. It never merges, and it never "
                 + "starts while its last run has not ended. Every result comes to your desk.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, LoamTheme.space1)
        }
    }

    /// The launchd agent. Without it, recurring runs start only while the app is open.
    private var agent: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start recurring runs while Loam is closed").loamText(LoamTheme.bodyStyle)
                Text(agentDetail).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("Start recurring runs while Loam is closed", isOn: Binding(
                get: { model.tickStatus?.installed == true },
                set: { on in Task { await model.setTickAgent(installed: on) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.tickStatus == nil)
                .accessibilityIdentifier("recurring-agent")
        }
        .padding(LoamTheme.space3)
        .loamCard()
    }

    private var agentDetail: String {
        guard let status = model.tickStatus else { return "Loam reads the launchd agent." }
        var words = status.installed
            ? "launchd runs loam tick every \(status.interval / 60) minutes while you are logged in."
            : "Off: recurring runs start only while Loam is open."
        if let last = status.lastTick {
            words += " Last tick: \(RecurringWords.when(last.at))."
            if !last.error.isEmpty { words += " It failed: \(last.error)" }
        }
        return words
    }
}

/// One recurring run: its title and kind, its timetable, its precheck, its next time, and what the last time did.
private struct RecurringCard: View {
    let model: AppModel
    let item: Recurring

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Text(item.title).loamText(LoamTheme.rowStyle).lineLimit(1)
                Text(item.kind == .shape ? "Shape only" : "Chore")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(LoamColor.rule))
                Spacer(minLength: LoamTheme.space3)
                Text(RecurringWords.timetable(days: item.days, at: item.at))
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                Group {
                    if item.precheck.isEmpty {
                        Text("No precheck: it starts each time").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    } else {
                        Text(item.precheck).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Next: \(RecurringWords.when(item.nextAt))").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                Text(last).loamText(LoamTheme.bodyStyle, item.lastAt == nil ? LoamColor.inkMuted : LoamColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Run now") { Task { await model.runRecurringNow(item.id) } }
                    .loamSecondaryButton()
                    .help("Start it now, with its precheck. Its next time stays.")
                    .accessibilityIdentifier("recurring-run-\(item.id)")
                Button("Remove") { Task { await model.removeRecurring(item.id) } }
                    .loamSecondaryButton()
                    .help("Remove the recurring run. Its runs stay.")
                    .accessibilityIdentifier("recurring-remove-\(item.id)")
            }
            .padding(.top, LoamTheme.space1)
        }
        .padding(.horizontal, LoamTheme.space3)
        .padding(.vertical, 10)
        .loamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recurring-\(item.id)")
    }

    private var last: String {
        guard let at = item.lastAt else { return "It has not run yet." }
        return "Last: \(RecurringWords.when(at)). \(item.lastNote)"
    }
}

/// The form for a new recurring run.
private struct RecurringForm: View {
    let model: AppModel
    let plotID: String
    @State private var draft = RecurringDraft()
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            Text("New recurring run").loamText(LoamTheme.rowStyle)
            field("Title") {
                TextField("Title", text: $draft.title, prompt: Text("Such as: Shape new issues"))
                    .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                    .padding(.horizontal, 9).frame(height: 28).loamFieldBox()
                    .accessibilityIdentifier("recurring-title")
            }
            field("What Claude does") {
                TextField("What Claude does", text: $draft.prompt, axis: .vertical)
                    .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                    .lineLimit(2...5)
                    .padding(.horizontal, 9).padding(.vertical, 6).loamFieldBox()
                    .accessibilityIdentifier("recurring-prompt")
            }
            HStack(alignment: .top, spacing: LoamTheme.space3) {
                field("When") {
                    HStack(spacing: 6) {
                        Picker("Days", selection: $draft.days) {
                            ForEach(RecurringWords.daySets, id: \.name) { set in Text(set.name).tag(set.days) }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("recurring-days")
                        TextField("Time", text: $draft.at)
                            .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.bodyStyle).monospacedDigit()
                            .padding(.horizontal, 8).frame(width: 64, height: 28).loamFieldBox()
                            .accessibilityLabel("Time")
                            .accessibilityIdentifier("recurring-at")
                    }
                }
                field("If the Mac is asleep") {
                    Picker("If the Mac is asleep", selection: $draft.ifAsleep) {
                        Text("Run once when it wakes").tag(Recurring.IfAsleep.once)
                        Text("Skip it").tag(Recurring.IfAsleep.skip)
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("recurring-if-asleep")
                }
            }
            field("Precheck, optional. A run starts only when it exits 0.") {
                TextField("Precheck", text: $draft.precheck, prompt: Text("Such as: gh issue list --label bug --json number --jq length | grep -qv '^0$'"))
                    .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.codeStyle)
                    .padding(.horizontal, 9).frame(height: 28).loamFieldBox()
                    .accessibilityIdentifier("recurring-precheck")
            }
            HStack(spacing: LoamTheme.space2) {
                kind(.shape, "Shape only", "Claude drafts runs. You approve each one.")
                kind(.chore, "Chore", "Runs to the gate, then waits for you to land it.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Kind")
            ModelEffortPickers(model: $draft.model, effort: $draft.effort,
                               defaults: model.runDefaults?.plotID == plotID ? model.runDefaults : nil, id: "recurring")
            if let error = model.recurringError {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                    .accessibilityIdentifier("recurring-error")
            }
            Divider()
            HStack(spacing: LoamTheme.space2) {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { draft = RecurringDraft(); model.clearRecurringError() }
                    .loamSecondaryButton()
                    .accessibilityIdentifier("recurring-cancel")
                Button("Add recurring run") { add() }
                    .loamPrimaryButton()
                    .disabled(busy || draft.title.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("recurring-add")
            }
        }
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kind(_ kind: Recurring.Kind, _ title: String, _ detail: String) -> some View {
        Button { draft.kind = kind } label: {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Image(systemName: draft.kind == kind ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(draft.kind == kind ? LoamColor.moss : LoamColor.inkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).loamText(LoamTheme.bodyStyle)
                    Text(detail).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(draft.kind == kind ? LoamColor.inkSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
        .accessibilityIdentifier("recurring-kind-\(kind.rawValue)")
    }

    private func add() {
        busy = true
        Task {
            if await model.addRecurring(draft) { draft = RecurringDraft() }
            busy = false
        }
    }
}

/// The rules of the plot (ticket 209): checks that every run must pass, with a form that adds one.
/// The model, the effort, and the MCP servers that a run of the plot gets when it names none: a run from Intake, a
/// recurring run, or `loam run start`. Default leaves the model and the effort to Claude Code, and the servers
/// default to none. A change saves at once. The pickers wait until the defaults of the plot are read.
private struct RunDefaultsSection: View {
    let model: AppModel
    let plotID: String
    @State private var sandbox: SandboxSettingsModel
    @State private var chosenModel = ""
    @State private var chosenEffort = ""
    @State private var chosenServers: [String] = []
    @State private var chosenReview = true
    @State private var chosenReviewEffort = ""
    /// What the pickers held when the page last asked the core to save, or when it loaded them. A save of the same
    /// pick is not needed, and the core may not have answered the last save yet.
    @State private var requested = RunDefaultsChoice(model: "", effort: "", servers: [], review: true, reviewEffort: "")
    /// True once the pickers hold the defaults that the core read for this plot.
    @State private var isLoaded = false
    /// True when the read of the defaults of this plot failed. The pickers stay off, so no save writes empty values.
    @State private var readFailed = false

    init(model: AppModel, plotID: String) {
        self.model = model
        self.plotID = plotID
        _sandbox = State(initialValue: SandboxSettingsModel(client: model.client, plot: plotID))
    }

    /// The switch for the code review before a push, and the effort of that review. The effort is off while the
    /// review is off.
    private var reviewControls: some View {
        HStack(alignment: .top, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                Toggle("Code review before push", isOn: $chosenReview)
                    .toggleStyle(.switch)
                    .help("Claude reviews the diff of a run before Loam pushes it. A Critical or Major finding goes back to the session.")
                    .accessibilityIdentifier("run-defaults-review")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Review effort").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                Picker("Review effort", selection: $chosenReviewEffort) {
                    ForEach(RunChoices.efforts) { choice in
                        Text(choice.value.isEmpty ? "Default" : choice.title).tag(choice.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!chosenReview)
                .help("The effort of the code review. Default is the default of Claude Code.")
                .accessibilityIdentifier("run-defaults-review-effort")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!isLoaded)
        .frame(maxWidth: 560, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            Text("Model, effort, MCP servers, and code review").loamText(LoamTheme.rowStyle)
            Text("Each run of this plot uses these, unless its form picks others. Default is the default of Claude Code.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            ModelEffortPickers(model: $chosenModel, effort: $chosenEffort, defaults: nil, id: "run-defaults",
                               help: "The model and the effort that a run of this plot gets when it names none") {
                MCPServerPicker(servers: model.mcpServers, selected: $chosenServers, id: "run-defaults-mcp")
            }
            .disabled(!isLoaded)
            .frame(maxWidth: 560, alignment: .leading)
            reviewControls
            Text("The MCP servers load when Claude drafts a run, writes its PR text, and reviews the code. Only servers added with "
                 + "claude mcp add --scope user show up. Claude.ai connectors cannot be selected. The tools of a selected "
                 + "server run as your Claude Code permissions allow.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("run-defaults-mcp-note")
            if readFailed {
                Text("Loam could not read the run defaults of this plot.").loamText(LoamTheme.captionStyle, LoamColor.rust)
                    .accessibilityIdentifier("run-defaults-read-error")
            }
            if let error = model.runDefaultsError {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                    .accessibilityIdentifier("run-defaults-error")
            }
            Divider()
            Text("Sandbox").loamText(LoamTheme.rowStyle)
            Text("A run works in a sandbox. Add what this plot needs beyond the presets for its stacks. "
                 + "The settings in Settings > Runs hold for every plot. Loam refuses a path that opens your home folder. A change holds for the next new session of a run.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            SandboxListsView(model: sandbox, scope: "plot")
                .frame(maxWidth: 560, alignment: .leading)
        }
        .task {
            async let servers: Void = model.readMCPServers()
            await model.readRunDefaults(plot: plotID)
            guard model.runDefaults?.plotID == plotID else {
                readFailed = true
                return await servers
            }
            requested = RunDefaultsChoice(model.runDefaults)
            chosenModel = requested.model
            chosenEffort = requested.effort
            chosenServers = requested.servers
            chosenReview = requested.review
            chosenReviewEffort = requested.reviewEffort
            isLoaded = true
            await servers
        }
        .onChange(of: RunDefaultsChoice(
            model: chosenModel, effort: chosenEffort, servers: chosenServers, review: chosenReview,
            reviewEffort: chosenReviewEffort)) { _, now in
            guard RunDefaultsChoice.needsSave(now, requested: requested, loaded: isLoaded ? model.runDefaults : nil, plot: plotID)
            else { return }
            let previous = requested
            requested = now
            let change = now.change(from: previous)
            Task {
                await model.setRunDefaults(
                    plot: plotID, model: change.model, effort: change.effort, mcpServers: change.servers,
                    review: change.review, reviewEffort: change.reviewEffort)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run-defaults")
    }
}

private struct RulesSection: View {
    let model: AppModel
    @State private var name = ""
    @State private var command = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rules").loamText(LoamTheme.rowStyle)
                Text("A rule is a check that every run of the plot must pass. The gate runs it after the checks of each "
                     + "run, and a run cannot change it. When you send back the same kind of note on two runs, the desk "
                     + "offers to make it a rule.")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.rules.isEmpty {
                Text("This plot has no rule yet.")
                    .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                    .accessibilityIdentifier("rules-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rules) { rule in
                        if rule.id != model.rules.first?.id { Divider() }
                        RuleRow(model: model, rule: rule)
                    }
                }
                .loamCard()
            }
            HStack(spacing: LoamTheme.space2) {
                TextField("Name", text: $name, prompt: Text("Such as: Use colour tokens"))
                    .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                    .padding(.horizontal, 9).frame(width: 220, height: 28).loamFieldBox()
                    .accessibilityLabel("Rule name")
                    .accessibilityIdentifier("rule-name")
                TextField("Command", text: $command, prompt: Text("A command that exits 0 when the rule holds"))
                    .labelsHidden().textFieldStyle(.plain).loamText(LoamTheme.codeStyle)
                    .padding(.horizontal, 9).frame(height: 28).loamFieldBox()
                    .onSubmit(add)
                    .accessibilityLabel("Rule command")
                    .accessibilityIdentifier("rule-command")
                Button("Add rule", action: add)
                    .loamPrimaryButton()
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("rule-add")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rules")
    }

    private func add() {
        guard !busy else { return }
        busy = true
        Task {
            if await model.addRule(name: name, command: command) {
                name = ""
                command = ""
            }
            busy = false
        }
    }
}

/// One rule: its name, its command, and the note that it came from.
private struct RuleRow: View {
    let model: AppModel
    let rule: Rule

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).loamText(LoamTheme.bodyStyle).lineLimit(1)
                Text(rule.command).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if !rule.note.isEmpty {
                    Text("From the note \u{201C}\(rule.note)\u{201D}").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove") { Task { await model.removeRule(rule.id) } }
                .loamSecondaryButton()
                .help("Remove the rule. The gate stops running it.")
                .accessibilityIdentifier("rule-remove-\(rule.id)")
        }
        .padding(.horizontal, LoamTheme.space3)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule-\(rule.id)")
    }
}
