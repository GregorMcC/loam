import LoamKit
import SwiftUI

/// The desk (ticket 207): the runs that wait for you, one at a time. A run in Shaping shows Claude's draft, for you
/// to edit and approve. A run that is ready shows its work by file, with your notes on its lines, the evidence that
/// it is done, and Send back and Merge. J and K move through the queue, and Esc leaves for Today. While you type in
/// a field, the keys type into it, and Esc leaves the field.
struct DeskView: View {
    let model: AppModel
    @FocusState private var field: DeskField?

    var body: some View {
        let queue = model.deskQueue
        let run = model.desk.runID.flatMap { id in model.runs.first { $0.id == id } }
        VStack(spacing: 0) {
            DeskBar(model: model, queue: queue, typing: field != nil)
            Divider()
            if let offer = model.desk.ruleOffer {
                DeskRuleOfferCard(model: model, offer: offer, field: $field)
                    .id(offer.offer.note)
                Divider()
            }
            if let run, run.state == .shaping {
                DeskShape(model: model, run: run, field: $field)
            } else if let run {
                DeskItem(model: model, run: run, field: $field)
            } else {
                DeskEmpty(model: model)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk")
    }
}

/// The note field that has the focus. A key of the desk has no modifier, so it works only while no field does.
enum DeskField: Hashable {
    case line
    case run
    case goal
    case check
    case answer
    case change
    case ruleName
    case ruleCommand
}

extension View {
    /// The key of the desk, or none while you type in a note.
    func deskKey(_ key: KeyEquivalent, typing: Bool) -> some View {
        keyboardShortcut(typing ? nil : KeyboardShortcut(key, modifiers: []))
    }
}

/// The rule that Loam offers after a send-back (ticket 209): the note is like a note that you sent back on another
/// run of the plot, so a check can catch it on every run. You name the rule and give its command. The offer stays
/// while you move through the queue.
private struct DeskRuleOfferCard: View {
    let model: AppModel
    let offer: DeskRuleOffer
    let field: FocusState<DeskField?>.Binding
    @State private var name: String
    @State private var command = ""
    @State private var busy = false

    init(model: AppModel, offer: DeskRuleOffer, field: FocusState<DeskField?>.Binding) {
        self.model = model
        self.offer = offer
        self.field = field
        _name = State(initialValue: Self.name(from: offer.offer.note))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Image(systemName: "checkmark.seal").foregroundStyle(LoamColor.moss)
                Text("Make this note a rule?").loamText(LoamTheme.rowStyle)
                Text("You sent back a note like it on \u{201C}\(offer.offer.earlierTitle)\u{201D}: \u{201C}\(offer.offer.earlier)\u{201D}")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Text("A rule is a check that every run of the plot must pass. The gate runs it after the checks of each run.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            HStack(spacing: LoamTheme.space2) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                    .padding(.horizontal, 9).frame(width: 200, height: 28).loamFieldBox()
                    .focused(field, equals: .ruleName)
                    .accessibilityLabel("Rule name")
                    .accessibilityIdentifier("desk-rule-name")
                TextField("Command", text: $command, prompt: Text("A command that exits 0 when the rule holds"))
                    .textFieldStyle(.plain).loamText(LoamTheme.codeStyle)
                    .padding(.horizontal, 9).frame(height: 28).loamFieldBox()
                    .focused(field, equals: .ruleCommand)
                    .onSubmit(add)
                    .accessibilityLabel("Rule command")
                    .accessibilityIdentifier("desk-rule-command")
                Button("Not now") { model.dismissDeskRuleOffer() }
                    .loamSecondaryButton()
                    .help("Loam offers it again the next time that you send back a note like it")
                    .accessibilityIdentifier("desk-rule-not-now")
                Button("Add rule", action: add)
                    .loamPrimaryButton()
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("desk-rule-add")
            }
            if let error = offer.error {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                    .accessibilityIdentifier("desk-rule-error")
            }
        }
        .padding(.horizontal, LoamTheme.space6)
        .padding(.vertical, LoamTheme.space3)
        .background(LoamColor.mossWash)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-rule-offer")
    }

    private func add() {
        guard !busy else { return }
        busy = true
        Task {
            if await model.addDeskRule(name: name, command: command) { field.wrappedValue = nil }
            busy = false
        }
    }

    /// The note as a name: its first sentence, with no "please" and no full stop.
    static func name(from note: String) -> String {
        var name = note.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? note
        for please in [", please", "Please, ", "Please "] {
            name = name.replacingOccurrences(of: please, with: "", options: [.caseInsensitive])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// The top bar: where you are in the queue, and the buttons that move through it.
private struct DeskBar: View {
    let model: AppModel
    let queue: [Run]
    let typing: Bool

    var body: some View {
        let index = queue.firstIndex { $0.id == model.desk.runID }
        HStack(spacing: LoamTheme.space3) {
            Text("The desk").loamText(LoamTheme.rowStyle)
            if let index {
                Text("\(index + 1) of \(queue.count)").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
                HStack(spacing: 4) {
                    ForEach(queue.indices, id: \.self) { i in
                        Capsule().fill(i == index ? LoamColor.ink : i < index ? LoamColor.inkMuted : LoamColor.inkKey)
                            .frame(width: 24, height: 4)
                    }
                }
                .accessibilityHidden(true)
            }
            Spacer()
            Button("Previous") { Task { await model.moveDesk(by: -1) } }
                .deskKey("k", typing: typing)
                .disabled(index == nil || index == 0)
                .help("Previous item (K)")
                .accessibilityIdentifier("desk-previous")
            Button("Next") { Task { await model.moveDesk(by: 1) } }
                .deskKey("j", typing: typing)
                .disabled(index == nil || index == queue.count - 1)
                .help("Next item (J)")
                .accessibilityIdentifier("desk-next")
            Button("Leave the desk") { model.leaveDesk() }
                .keyboardShortcut(typing ? nil : .cancelAction)
                .help("Back to Today (Esc)")
                .accessibilityIdentifier("desk-leave")
        }
        .loamSecondaryButton()
        .padding(.horizontal, LoamTheme.space6)
        .padding(.vertical, LoamTheme.space3)
    }
}

/// What the desk shows when no run waits for you.
private struct DeskEmpty: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: LoamTheme.space3) {
            Text("Nothing waits for you").loamText(LoamTheme.emptyTitleStyle)
            Text("A run comes to the desk when Claude has drafted it, when it is ready to land, or when it stops.")
                .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
            Button("Back to Today") { model.leaveDesk() }.loamSecondaryButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-empty")
    }
}

/// One run at the desk: its header, its files, the diff of one file, the evidence, and the actions.
private struct DeskItem: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            DeskItemHeader(model: model, run: run)
            Divider()
            HStack(spacing: 0) {
                DeskFiles(model: model, typing: field.wrappedValue != nil)
                    .frame(width: 240)
                Divider()
                DeskDiff(model: model, field: field)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DeskEvidence(model: model, run: run, field: field)
                    .frame(width: 300)
            }
            Divider()
            DeskActions(model: model, run: run)
        }
    }
}

/// The station, plot, issue and PR of the run, and its title.
struct DeskItemHeader: View {
    let model: AppModel
    let run: Run

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AttentionDot(mark: run.state == .ready ? .unread : .needs).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(context).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            Text(run.title).loamText(LoamTheme.plotNameStyle).textSelection(.enabled)
                .accessibilityIdentifier("desk-item-title")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LoamTheme.space6)
        .padding(.vertical, LoamTheme.space4)
    }

    private var context: String {
        let station = switch run.state {
        case .shaping: "Shape"
        case .ready: "Land"
        default: "Stopped"
        }
        var parts = [station, model.plots.first { $0.id == run.plotID }?.name ?? ""]
        if let source = run.source { parts.append(source.label) }
        if let pr = run.pr { parts.append("#\(pr.number)") }
        if let size = run.shape?.size, run.state == .shaping { parts.append(size) }
        if run.state != .shaping { parts.append("\(run.tries) of \(run.maxTries) tries used") }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}

/// The files of the diff, in the order of git. A click shows a file.
private struct DeskFiles: View {
    let model: AppModel
    let typing: Bool

    var body: some View {
        let files = model.desk.diff?.files ?? []
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(summary(files)).loamLabel()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { file in
                        let notes = model.desk.currentNotes.filter { $0.file == file.path }.count
                        Button { model.showDeskFile(file.path) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.path).loamText(LoamTheme.codeStyle).lineLimit(1).truncationMode(.head)
                                Text(detail(file, notes: notes)).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, LoamTheme.space2)
                            .padding(.vertical, 6)
                            .background(model.desk.file == file.path ? LoamColor.inkSelected : .clear,
                                        in: RoundedRectangle(cornerRadius: LoamTheme.radiusSm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(file.oldPath.map { "Renamed from \($0)" } ?? file.path)
                        .accessibilityIdentifier("desk-file-\(file.path)")
                    }
                }
            }
            if let next = nextFile(files) {
                Button("Next file") { model.showDeskFile(next) }
                    .deskKey("]", typing: typing)
                    .loamSecondaryButton()
                    .help("Next file (])")
                    .accessibilityIdentifier("desk-next-file")
            }
        }
        .padding(LoamTheme.space4)
    }

    private func summary(_ files: [RunDiff.File]) -> String {
        let added = files.reduce(0) { $0 + $1.added }, deleted = files.reduce(0) { $0 + $1.deleted }
        let count = files.count == 1 ? "1 file" : "\(files.count) files"
        return "\(count) \u{00B7} +\(added) \u{2212}\(deleted)"
    }

    private func detail(_ file: RunDiff.File, notes: Int) -> String {
        var parts = [file.status.capitalized, "+\(file.added) \u{2212}\(file.deleted)"]
        if notes > 0 { parts.append(notes == 1 ? "1 note" : "\(notes) notes") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func nextFile(_ files: [RunDiff.File]) -> String? {
        guard let i = files.firstIndex(where: { $0.path == model.desk.file }), i + 1 < files.count else { return nil }
        return files[i + 1].path
    }
}

/// The diff of the file that the desk shows. A click on the number of a line opens a note on it. Your notes
/// show under their lines.
private struct DeskDiff: View {
    let model: AppModel
    @State private var editing: Int?
    let field: FocusState<DeskField?>.Binding
    @State private var draft = ""

    var body: some View {
        let file = model.desk.diff?.files.first { $0.path == model.desk.file }
        VStack(alignment: .leading, spacing: 0) {
            if let file {
                HStack {
                    Text(file.path).loamText(LoamTheme.codeStyle)
                    Spacer()
                    Text("Click a line number to add a note").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                .padding(.horizontal, LoamTheme.space4)
                .padding(.vertical, LoamTheme.space2)
                Divider()
                // One axis only: a LazyVStack in a two-axis ScrollView has no width to fill. A long line wraps.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if file.binary == true {
                            message("A binary file. The desk does not show it.")
                        }
                        ForEach(DiffRow.rows(file)) { row in
                            switch row.content {
                            case .header(let header):
                                Text(header).loamText(LoamTheme.codeStyle, LoamColor.inkFaint)
                                    .padding(.horizontal, LoamTheme.space4).padding(.vertical, 6)
                            case .line(let line):
                                lineRow(line)
                                if let number = line.new {
                                    notes(file.path, number)
                                    if editing == number { editor(file.path, number) }
                                }
                            }
                        }
                        if file.truncated == true {
                            message("The file has more lines than the desk shows.")
                        }
                    }
                    .padding(.vertical, LoamTheme.space2)
                }
            } else if model.desk.diff != nil {
                message("The run committed no change.")
            } else if model.desk.error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LoamColor.bedrock)
        .onChange(of: model.desk.file) { editing = nil }
        .onChange(of: model.desk.runID) { editing = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-diff")
    }

    private func lineRow(_ line: RunDiff.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Group {
                if let number = line.new {
                    Button(String(number)) { open(number) }
                        .buttonStyle(.plain)
                        .help("Add a note on line \(number)")
                        .accessibilityIdentifier("desk-line-\(number)")
                } else {
                    Text("")
                }
            }
            .frame(width: 40, alignment: .trailing)
            Text(marker(line.kind)).frame(width: 20)
                .foregroundStyle(line.kind == .add ? LoamColor.moss : line.kind == .del ? LoamColor.rust : LoamColor.inkFaint)
            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(LoamColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .loamText(LoamTheme.codeStyle, LoamColor.inkFaint)
        .padding(.trailing, LoamTheme.space4)
        .background(line.kind == .add ? LoamColor.mossWash : line.kind == .del ? LoamColor.rustWash : .clear)
    }

    @ViewBuilder
    private func notes(_ path: String, _ number: Int) -> some View {
        ForEach(model.desk.currentNotes.filter { $0.file == path && $0.line == number }) { note in
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Text(note.text).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Remove") { model.removeDeskNote(note.id) }
                    .buttonStyle(.plain)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            .padding(LoamTheme.space3)
            .loamCard()
            .padding(.leading, 100).padding(.trailing, LoamTheme.space4).padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("desk-note-\(number)")
        }
    }

    private func editor(_ path: String, _ number: Int) -> some View {
        HStack(spacing: LoamTheme.space2) {
            TextField("Your note on line \(number)", text: $draft)
                .textFieldStyle(.plain)
                .loamText(LoamTheme.bodyStyle)
                .focused(field, equals: .line)
                // The field is new, so the focus goes to it once it shows, not when the click opens it. SwiftUI can drop
                // a first try, as in the sheet for a new worktree, so it tries a few times.
                .task {
                    for _ in 0..<5 where field.wrappedValue != .line {
                        field.wrappedValue = .line
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
                .onSubmit { save(path, number) }
                .accessibilityLabel("Note on line \(number)")
                .accessibilityIdentifier("desk-note-field")
            Button("Save") { save(path, number) }
                .loamPrimaryButton()
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("desk-note-save")
            Button("Cancel") { editing = nil }
                .keyboardShortcut(.cancelAction)
                .loamSecondaryButton()
        }
        .padding(LoamTheme.space3)
        .loamFieldBox()
        .padding(.leading, 100).padding(.trailing, LoamTheme.space4).padding(.vertical, 4)
    }

    private func message(_ text: String) -> some View {
        Text(text).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).padding(LoamTheme.space4)
    }

    private func marker(_ kind: RunDiff.Line.Kind) -> String {
        switch kind {
        case .add: "+"
        case .del: "\u{2212}"
        case .context: ""
        }
    }

    private func open(_ number: Int) {
        draft = ""
        editing = editing == number ? nil : number
    }

    private func save(_ path: String, _ number: Int) {
        model.addDeskNote(file: path, line: number, text: draft)
        draft = ""
        editing = nil
    }
}

/// A row of the diff: a hunk header or a line. The rows of all hunks go in one ForEach with an id each, because
/// ForEach loops nested in a LazyVStack with offsets for ids give the first line the id of its hunk, and the
/// stack draws only one of the two.
private struct DiffRow: Identifiable {
    enum Content {
        case header(String)
        case line(RunDiff.Line)
    }

    let id: String
    let content: Content

    static func rows(_ file: RunDiff.File) -> [DiffRow] {
        file.hunks.enumerated().flatMap { h, hunk in
            [DiffRow(id: "\(h)", content: .header(hunk.header))]
                + hunk.lines.enumerated().map { l, line in DiffRow(id: "\(h).\(l)", content: .line(line)) }
        }
    }
}

/// Why the run is at the desk: its note, the checks, the tries, CI, and what a merge does. A note on the whole
/// run goes here too.
private struct DeskEvidence: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var draft = ""

    var body: some View {
        let events = model.runStatus?.run.id == run.id ? model.runStatus?.events ?? [] : []
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space4) {
                if !run.note.isEmpty {
                    Text(run.note).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                        .padding(LoamTheme.space3).frame(maxWidth: .infinity, alignment: .leading).loamCard()
                        .accessibilityIdentifier("desk-run-note")
                }
                section("Evidence") {
                    row(run.doneWhen.isEmpty ? "Work committed" : "Done when \u{00B7} \(run.doneWhen.count + 1) checks",
                        run.state == .ready ? "All passed" : "")
                    row("Tries", "\(run.tries) of \(run.maxTries) used")
                    ForEach(events.filter { ["ci", "ship", "linear", "review"].contains($0.kind) }.suffix(6)) { event in
                        row(event.detail, ChangeRules.clock(event.at))
                    }
                }
                .accessibilityIdentifier("desk-evidence")
                if run.state == .ready, run.pr != nil {
                    section("When you merge") {
                        if let source = run.source, source.kind == "linear" {
                            Text("Linear: \(source.key) moves to Done").loamText(LoamTheme.bodyStyle)
                        }
                        Toggle("Keep the worktree", isOn: Binding(
                            get: { model.desk.keepWorktree }, set: { model.setDeskKeepWorktree($0) }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("desk-keep-worktree")
                    }
                }
                section("A note on the whole run") {
                    ForEach(model.desk.currentNotes.filter { $0.file == nil }) { note in
                        HStack(alignment: .firstTextBaseline) {
                            Text(note.text).loamText(LoamTheme.bodyStyle)
                            Spacer()
                            Button("Remove") { model.removeDeskNote(note.id) }
                                .buttonStyle(.plain).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        }
                    }
                    TextField("Such as: add a test for the empty case", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused(field, equals: .run)
                        .onExitCommand { field.wrappedValue = nil }
                        .onSubmit {
                            model.addDeskNote(file: nil, line: nil, text: draft)
                            draft = ""
                        }
                        .accessibilityLabel("Note on the whole run")
                        .accessibilityIdentifier("desk-run-note-field")
                }
            }
            .padding(LoamTheme.space4)
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(title).loamLabel()
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ text: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).loamText(LoamTheme.bodyStyle)
            Spacer(minLength: LoamTheme.space2)
            Text(detail).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
        }
    }
}

/// Send back and Merge, and why the last one failed.
private struct DeskActions: View {
    let model: AppModel
    let run: Run

    var body: some View {
        let notes = model.desk.currentNotes.count
        HStack(spacing: LoamTheme.space3) {
            Button(notes == 0 ? "Send back" : notes == 1 ? "Send back 1 note" : "Send back \(notes) notes") {
                Task { await model.sendBackDeskNotes() }
            }
            .loamSecondaryButton()
            .disabled(notes == 0 || model.desk.busy)
            .help("Resume the run's session with your notes. The checks run again before the run comes back.")
            .accessibilityIdentifier("desk-send-back")
            if run.state == .ready, let pr = run.pr {
                Button("Merge #\(pr.number)") { Task { await model.landDeskRun() } }
                    .loamPrimaryButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.desk.busy || model.desk.diff == nil)
                    .help("Merge the PR with the repo's default method (\u{2318}\u{21A9})")
                    .accessibilityIdentifier("desk-merge")
            }
            if model.desk.busy { ProgressView().controlSize(.small) }
            if let error = model.desk.error {
                Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("desk-error")
            } else {
                Text(hint).loamText(LoamTheme.captionStyle, LoamColor.inkMuted).lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, LoamTheme.space6)
        .padding(.vertical, LoamTheme.space3)
    }

    private var hint: String {
        run.state == .ready
            ? "Send back resumes the session with your notes. The checks and CI run again before the run comes back."
            : "The run stopped. Send back resumes its session with your notes, with one more try if it used them all."
    }
}
