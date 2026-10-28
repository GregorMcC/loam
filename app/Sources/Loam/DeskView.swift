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

/// The top bar: where you are in the queue, and Leave the desk.
private struct DeskBar: View {
    let model: AppModel
    let queue: [Run]
    let typing: Bool

    var body: some View {
        let index = queue.firstIndex { $0.id == model.desk.runID }
        HStack(spacing: 14) {
            Text("The desk").loamText(LoamTheme.windowTitleStyle)
            if let index {
                Text("\(index + 1) of \(queue.count)").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
                HStack(spacing: 4) {
                    ForEach(queue.indices, id: \.self) { i in
                        Capsule().fill(i == index ? LoamColor.ink : i < index ? LoamColor.inkMuted : LoamColor.inkKey)
                            .frame(width: 28, height: 4)
                    }
                }
                .accessibilityHidden(true)
            }
            Spacer()
            Button { model.leaveDesk() } label: {
                HStack(spacing: LoamTheme.space2) {
                    Text("Leave the desk")
                    Keycap(text: "esc")
                }
            }
            .loamSecondaryButton()
            .keyboardShortcut(typing ? nil : .cancelAction)
            .help("Back to Today (Esc)")
            .accessibilityIdentifier("desk-leave")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

/// The key hints at the right of the footer: Previous and Next, and on a run with work, Next file. Each one is a
/// button, and its key works while no field has the focus.
struct DeskNavHints: View {
    let model: AppModel
    let typing: Bool
    var showsNextFile = false

    var body: some View {
        let queue = model.deskQueue
        let index = queue.firstIndex { $0.id == model.desk.runID }
        HStack(spacing: LoamTheme.space3) {
            DeskHint(title: "Previous", key: "K") { Task { await model.moveDesk(by: -1) } }
                .deskKey("k", typing: typing)
                .disabled(index == nil || index == 0)
                .help("Previous item (K)")
                .accessibilityIdentifier("desk-previous")
            if showsNextFile {
                DeskHint(title: "Next file", key: "]") { model.showNextDeskFile() }
                    .deskKey("]", typing: typing)
                    .disabled(model.nextDeskFile == nil)
                    .help("Next file (])")
                    .accessibilityIdentifier("desk-next-file")
            }
            DeskHint(title: showsNextFile ? "Next item" : "Next", key: "J") { Task { await model.moveDesk(by: 1) } }
                .deskKey("j", typing: typing)
                .disabled(index == nil || index == queue.count - 1)
                .help("Next item (J)")
                .accessibilityIdentifier("desk-next")
        }
    }
}

/// A key hint that is a button: a caption and its keycap.
private struct DeskHint: View {
    let title: String
    let key: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                Keycap(text: key)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The keycap in the primary button: the text of the button on a darker ground.
struct DeskPrimaryKeycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 1)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

/// A button title with its keycap.
struct DeskKeyLabel: View {
    let title: String
    let key: String
    var primary = false

    var body: some View {
        HStack(spacing: LoamTheme.space2) {
            Text(title)
            if primary { DeskPrimaryKeycap(text: key) } else { Keycap(text: key) }
        }
    }
}

extension View {
    /// The heading of a part of the desk, such as Goal or Evidence: semibold, in `ink-faint`.
    func deskHeading() -> some View {
        font(.system(size: 12, weight: .semibold)).foregroundStyle(LoamColor.inkFaint)
    }
}

/// The queue at the left of a draft: the runs that wait, by station, with the run that the desk shows selected.
/// A click shows a run.
struct DeskQueue: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: LoamTheme.space4) {
            ScrollView {
                VStack(alignment: .leading, spacing: LoamTheme.space4) {
                    ForEach(DeskContent.queue(model.deskQueue, plots: model.plots)) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.title).deskHeading().padding(.leading, 10).padding(.bottom, LoamTheme.space2)
                            ForEach(group.rows) { row($0, station: group.station) }
                        }
                    }
                }
            }
            Text("Shape comes first, so new runs can start while you read the rest.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, LoamTheme.space3)
        .padding(.vertical, LoamTheme.space4)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-queue")
    }

    private func row(_ row: DeskContent.QueueRow, station: RunStation) -> some View {
        let current = row.id == model.desk.runID
        return Button { Task { await model.openDesk(row.id) } } label: {
            HStack(alignment: .top, spacing: 9) {
                AttentionDot(mark: station == .land ? .unread : .needs).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).loamText(current ? LoamTheme.rowStyle : LoamTheme.bodyStyle).lineLimit(2)
                    Text(row.caption).loamText(LoamTheme.captionStyle, row.stopped ? LoamColor.rust : LoamColor.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, LoamTheme.space2)
            .background(current ? LoamColor.inkSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desk-queue-\(row.id)")
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

/// One run with work at the desk: its header, its files in the order to read them, the diff of one file, the
/// evidence, and the actions.
private struct DeskItem: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding

    var body: some View {
        let files = DeskContent.readOrder(model.desk.diff?.files ?? [], notes: run.notes)
        VStack(spacing: 0) {
            DeskItemHeader(model: model, run: run)
            Divider()
            HStack(spacing: 0) {
                DeskFiles(model: model, run: run, files: files)
                    .frame(width: 264)
                Divider()
                DeskDiff(model: model, files: files, field: field)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DeskEvidence(model: model, run: run, field: field)
                    .frame(width: 344)
            }
            Divider()
            DeskActions(model: model, run: run, field: field)
        }
    }
}

/// The station, plot, issue and PR of the run, its title, and what each station did.
struct DeskItemHeader: View {
    let model: AppModel
    let run: Run

    var body: some View {
        let events = model.runStatus?.run.id == run.id ? model.runStatus?.events ?? [] : []
        HStack(alignment: .bottom, spacing: LoamTheme.space4) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: LoamTheme.space2) {
                    AttentionDot(mark: run.state == .ready ? .unread : .needs).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(DeskContent.context(run, plotName: model.plots.first { $0.id == run.plotID }?.name ?? "",
                                             repoName: model.repoName(of: run), events: events))
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                Text(run.title).loamText(LoamTheme.plotNameStyle).textSelection(.enabled)
                    .accessibilityIdentifier("desk-item-title")
                RunGroupLinks(model: model, run: run)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                ForEach(DeskContent.stations(run, events: events), id: \.self) { station in
                    Text(station).font(.system(size: 12)).foregroundStyle(LoamColor.inkMuted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("desk-stations")
        }
        .padding(.horizontal, LoamTheme.space6)
        .padding(.top, LoamTheme.space4)
        .padding(.bottom, LoamTheme.space3)
    }
}

/// The walkthrough that Claude wrote, and the files of the diff in the order to read them, with their roles. With
/// no ship notes, the files go in the order of git. A click shows a file.
private struct DeskFiles: View {
    let model: AppModel
    let run: Run
    let files: [DeskContent.ReadFile]

    var body: some View {
        let ordered = run.notes != nil
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space4) {
                if let walkthrough = run.notes?.walkthrough, !walkthrough.isEmpty {
                    VStack(alignment: .leading, spacing: LoamTheme.space1) {
                        Text("Walkthrough \u{00B7} Claude wrote this").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        Text(walkthrough).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, LoamTheme.space3).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .loamCard()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("desk-walkthrough")
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary(ordered)).deskHeading().padding(.leading, LoamTheme.space2).padding(.bottom, LoamTheme.space2)
                    ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                        row(file, number: ordered ? i + 1 : nil)
                    }
                }
            }
            .padding(.horizontal, LoamTheme.space3)
            .padding(.vertical, LoamTheme.space4)
        }
    }

    private func summary(_ ordered: Bool) -> String {
        let all = files.map(\.file)
        let lines = DeskContent.lineCounts(all)
        return ordered ? "Read in this order \u{00B7} \(lines)" : "\(all.count == 1 ? "1 file" : "\(all.count) files") \u{00B7} \(lines)"
    }

    private func row(_ file: DeskContent.ReadFile, number: Int?) -> some View {
        let notes = model.desk.currentNotes.filter { $0.file == file.file.path }.count
        return Button { model.showDeskFile(file.file.path) } label: {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                if let number {
                    Text("\(number)").loamText(LoamTheme.captionStyle, LoamColor.inkMuted).frame(width: 18, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.file.path).loamText(LoamTheme.codeStyle).lineLimit(1).truncationMode(.head)
                    Text(DeskContent.fileCaption(file, notes: notes)).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LoamTheme.space2)
            .padding(.vertical, 7)
            .background(model.desk.file == file.file.path ? LoamColor.inkSelected : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.file.oldPath.map { "Renamed from \($0)" } ?? file.file.path)
        .accessibilityIdentifier("desk-file-\(file.file.path)")
    }
}

/// The diff of the file that the desk shows. A click on the number of a line opens a note on it. Your notes
/// show under their lines.
private struct DeskDiff: View {
    let model: AppModel
    let files: [DeskContent.ReadFile]
    @State private var editing: Int?
    let field: FocusState<DeskField?>.Binding
    @State private var draft = ""

    var body: some View {
        let file = model.desk.diff?.files.first { $0.path == model.desk.file }
        VStack(alignment: .leading, spacing: 0) {
            if let file {
                HStack(spacing: 10) {
                    Text(file.path).loamText(LoamTheme.codeStyle).lineLimit(1).truncationMode(.head)
                    if let index = files.firstIndex(where: { $0.file.path == file.path }) {
                        Text("\(index + 1) of \(files.count)").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    }
                    Spacer()
                    Text("Click a line number to add a note").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
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
        .onChange(of: model.desk.file) { closeEditor() }
        .onChange(of: model.desk.runID) { closeEditor() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-diff")
    }

    private func lineRow(_ line: RunDiff.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.old.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
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
            .frame(width: 34, alignment: .trailing)
            Text(marker(line.kind)).frame(width: 22)
                .foregroundStyle(line.kind == .add ? LoamColor.moss : line.kind == .del ? LoamColor.rust : LoamColor.inkFaint)
            // The indent stays apart from the code, so a long line wraps under its code.
            let (indent, code) = line.indentAndCode
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !indent.isEmpty { Text(indent).fixedSize() }
                Text(code.isEmpty ? " " : code)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(LoamColor.ink)
        }
        .loamText(LoamTheme.codeStyle, LoamColor.inkFaint)
        .padding(.trailing, LoamTheme.space4)
        .background(line.kind == .add ? LoamColor.mossWash : line.kind == .del ? LoamColor.rustWash : .clear)
    }

    @ViewBuilder
    private func notes(_ path: String, _ number: Int) -> some View {
        ForEach(model.desk.currentNotes.filter { $0.file == path && $0.line == number }) { note in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: LoamTheme.space2) {
                    Text("Your note \u{00B7} line \(number)").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    Spacer()
                    Button("Remove") { model.removeDeskNote(note.id) }
                        .buttonStyle(.plain)
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
                Text(note.text).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, LoamTheme.space2)
            .loamCard(radius: 8)
            .padding(.leading, 82).padding(.trailing, 14).padding(.top, 4).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("desk-note-\(number)")
        }
    }

    private func editor(_ path: String, _ number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your note \u{00B7} line \(number) \u{00B7} editing").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
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
            HStack(spacing: LoamTheme.space2) {
                Spacer()
                Button("Cancel") { closeEditor() }
                    .keyboardShortcut(.cancelAction)
                    .loamSecondaryButton()
                    .accessibilityIdentifier("desk-note-cancel")
                Button { save(path, number) } label: { DeskKeyLabel(title: "Save note", key: "\u{21A9}", primary: true) }
                    .loamPrimaryButton()
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("desk-note-save")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, LoamTheme.space2)
        .loamCard(radius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.edge))
        .padding(.leading, 82).padding(.trailing, 14).padding(.top, 4).padding(.bottom, 6)
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
        closeEditor()
    }

    /// Closes the note field. The focus leaves the field first, and the field goes on the next turn: when SwiftUI
    /// removes a field that has the focus, no key of the desk works until the page draws again (TAS-52). A save does
    /// not need this, as Return ends the edit first, but it takes the same path.
    private func closeEditor() {
        guard let closing = editing else { return }
        if field.wrappedValue == .line { field.wrappedValue = nil }
        Task { @MainActor in
            if editing == closing { editing = nil }
        }
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

/// Why the run is at the desk: why it stopped, the evidence, the risk, and what a merge does. A note on the
/// whole run goes here too.
private struct DeskEvidence: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var draft = ""

    var body: some View {
        let events = model.runStatus?.run.id == run.id ? model.runStatus?.events ?? [] : []
        let lines = DeskContent.evidence(run, events: events)
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space4) {
                // The note of a ready run repeats the last line of the evidence, so only a stopped run shows it.
                if run.state != .ready, !run.note.isEmpty {
                    Text(run.note).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                        .padding(.horizontal, LoamTheme.space3).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).loamCard()
                        .accessibilityIdentifier("desk-run-note")
                }
                if !lines.isEmpty {
                    section("Evidence") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                                if i > 0 { Rectangle().fill(LoamColor.inkHairline).frame(height: 1) }
                                evidence(line)
                            }
                        }
                    }
                    .accessibilityIdentifier("desk-evidence")
                }
                if let risk = run.notes?.risk {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Risk: \(risk.level)").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(risk.level == "high" ? LoamColor.rust : LoamColor.ink)
                        if !risk.reasons.isEmpty {
                            Text(risk.reasons.joined(separator: " ")).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, LoamTheme.space3).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .loamCard()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("desk-risk")
                }
                if run.state == .ready, run.pr != nil {
                    section("When you merge") {
                        VStack(alignment: .leading, spacing: LoamTheme.space2) {
                            if let source = run.source, source.kind == "linear" {
                                let off = model.desk.linearUpdates?.done == false
                                Toggle("Linear: \(source.key) moves to Done", isOn: Binding(
                                    get: { !off && model.deskLinearDone }, set: { model.setDeskLinearDone($0) }))
                                    .disabled(off)
                                    .help(off ? "The Done update to Linear is off in Settings" : "Move \(source.key) to Done")
                                    .accessibilityIdentifier("desk-linear-done")
                            }
                            Toggle("Remove the worktree and branch", isOn: Binding(
                                get: { !model.desk.keepWorktree }, set: { model.setDeskKeepWorktree(!$0) }))
                                .help("The core keeps a worktree that has open panes")
                                .accessibilityIdentifier("desk-remove-worktree")
                            if let text = run.notes?.whereItStands, !text.isEmpty {
                                Toggle("Move Where it stands on", isOn: Binding(
                                    get: { model.desk.moveWhereItStands }, set: { model.setDeskMoveWhereItStands($0) }))
                                    .help(text)
                                    .accessibilityIdentifier("desk-where-it-stands")
                            }
                        }
                        .toggleStyle(.checkbox)
                        .loamText(LoamTheme.bodyStyle)
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
            .padding(.horizontal, 18)
            .padding(.vertical, LoamTheme.space4)
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text(title).deskHeading()
            content()
        }
        .accessibilityElement(children: .contain)
    }

    /// One line of the evidence: a tick or a count, the title, and its caption.
    private func evidence(_ line: DeskContent.EvidenceLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
            Group {
                switch line.mark {
                case .tick: Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(LoamColor.moss)
                case .count(let n): Text("\(n)").foregroundStyle(LoamColor.inkMuted)
                case .none: Text("")
                }
            }
            .font(.system(size: 12))
            .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title).font(.system(size: 12)).foregroundStyle(LoamColor.ink)
                if !line.caption.isEmpty {
                    Text(line.caption).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Send back and Merge, why the last one failed, and the keys that move through the desk.
private struct DeskActions: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding

    var body: some View {
        let typing = field.wrappedValue != nil
        let notes = model.desk.currentNotes.count
        HStack(spacing: 10) {
            Button {
                Task { await model.sendBackDeskNotes() }
            } label: {
                DeskKeyLabel(title: notes == 0 ? "Send back" : notes == 1 ? "Send back 1 note" : "Send back \(notes) notes", key: "S")
            }
            .loamSecondaryButton()
            .deskKey("s", typing: typing)
            .disabled(notes == 0 || model.desk.busy)
            .help("Resume the run's session with your notes. The checks run again before the run comes back. (S)")
            .accessibilityIdentifier("desk-send-back")
            if run.state == .ready, let pr = run.pr {
                Button { Task { await model.landDeskRun() } } label: {
                    DeskKeyLabel(title: "Merge #\(pr.number)", key: "\u{2318}\u{21A9}", primary: true)
                }
                .loamPrimaryButton()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.desk.busy || model.desk.diff == nil)
                .help("Merge the PR with the repo's default method (\u{2318}\u{21A9})")
                .accessibilityIdentifier("desk-merge")
            }
            if model.desk.busy { ProgressView().controlSize(.small) }
            Group {
                if let error = model.desk.error {
                    Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).textSelection(.enabled)
                        .accessibilityIdentifier("desk-error")
                } else {
                    Text(hint).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                }
            }
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            DeskNavHints(model: model, typing: typing, showsNextFile: true)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var hint: String {
        run.state == .ready
            ? "Send back resumes the run's session with your notes. The gate and CI run again before the run comes back to you."
            : "The run stopped. Send back resumes its session with your notes, with one more try if it used them all."
    }
}
