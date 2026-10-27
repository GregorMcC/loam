import LoamKit
import SwiftUI

/// A run in Shaping at the desk (ticket 207): Claude's draft of the goal, the checks, the assumptions and the plan.
/// You edit the goal and the checks in place, keep or change each assumption, and then approve the run, ask Claude
/// to change the draft, or leave it for now. A, C and N do the same while no field has the focus.
struct DeskShape: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            DeskItemHeader(model: model, run: run)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    DeskDraft(model: model, run: run, field: field)
                        .padding(LoamTheme.space6)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LoamColor.bedrock)
                Divider()
                DeskIfYouApprove(model: model, run: run)
                    .frame(width: 300)
            }
            Divider()
            DeskShapeActions(model: model, run: run, field: field)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-shape")
    }
}

/// The draft: the goal, the checks, the assumptions, the plan and the size. While Claude drafts, it says so. A
/// draft that failed shows why.
private struct DeskDraft: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var changing: Int?
    @State private var answer = ""

    var body: some View {
        let shape = run.shape
        let edit = model.desk.currentEdit
        VStack(alignment: .leading, spacing: LoamTheme.space6) {
            if model.desk.drafting.contains(run.id) || (shape?.isDrafted != true && run.note == Self.draftingNote) {
                HStack(spacing: LoamTheme.space2) {
                    ProgressView().controlSize(.small)
                    Text("Claude is drafting the run. This takes a minute or two.")
                        .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                }
                .accessibilityIdentifier("desk-drafting")
            } else if shape?.isDrafted != true {
                Text(run.note.isEmpty ? "Claude has not drafted the run." : run.note)
                    .loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                    .padding(LoamTheme.space3).frame(maxWidth: .infinity, alignment: .leading).loamCard()
                    .accessibilityIdentifier("desk-draft-failed")
            }
            if shape?.isDrafted == true {
                section("Goal", edited: edit.goal != nil) {
                    TextField("What done looks like", text: Binding(
                        get: { edit.goal ?? run.goal }, set: { model.editDeskGoal($0) }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .loamText(LoamTheme.briefStyle)
                        .lineLimit(1...6)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .loamFieldBox()
                        .focused(field, equals: .goal)
                        .onExitCommand { field.wrappedValue = nil }
                        .accessibilityLabel("Goal")
                        .accessibilityIdentifier("desk-goal")
                }
                section("Done when", edited: edit.checks != nil) {
                    DeskChecks(model: model, run: run, field: field)
                }
                if let shape, !shape.assumptions.isEmpty {
                    section("Assumptions", edited: !edit.answers.isEmpty) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shape.assumptions.enumerated()), id: \.offset) { i, assumption in
                                if i > 0 { Divider() }
                                assumptionRow(i, assumption.text, answer: edit.answers[i])
                            }
                        }
                        .loamCard()
                    }
                }
                if let shape, !shape.plan.isEmpty {
                    section("Plan", edited: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(shape.plan.enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                                    Text("\(i + 1).").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
                                        .frame(width: 20, alignment: .trailing)
                                    Text(step).loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if !shape.size.isEmpty {
                                Text(shape.size).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                                    .padding(.top, LoamTheme.space1)
                            }
                        }
                        .accessibilityIdentifier("desk-plan")
                    }
                }
            }
        }
        .onChange(of: run.id) { changing = nil }
    }

    /// The note of a run while Claude drafts it, as the core writes it.
    static let draftingNote = "Claude is drafting the run"

    private func section(_ title: String, edited: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            HStack(spacing: LoamTheme.space2) {
                Text(title).loamLabel()
                if edited { Text("Edited").loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
            }
            content()
        }
        .accessibilityElement(children: .contain)
    }

    /// One assumption, with Keep and Change. A changed assumption shows what you want in its place.
    private func assumptionRow(_ i: Int, _ text: String, answer current: String?) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                Text(text).loamText(LoamTheme.bodyStyle, current == nil ? LoamColor.ink : LoamColor.inkMuted)
                    .strikethrough(current != nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if changing != i {
                    Button("Keep") { model.answerDeskAssumption(i, "") }
                        .loamSecondaryButton()
                        .disabled(current == nil)
                        .accessibilityIdentifier("desk-assumption-keep-\(i)")
                    Button("Change") {
                        answer = current ?? ""
                        changing = i
                    }
                    .loamSecondaryButton()
                    .accessibilityIdentifier("desk-assumption-change-\(i)")
                }
            }
            if changing == i {
                HStack(spacing: LoamTheme.space2) {
                    TextField("What you want instead", text: $answer)
                        .textFieldStyle(.plain)
                        .loamText(LoamTheme.bodyStyle)
                        .padding(.horizontal, 9).frame(height: 28)
                        .loamFieldBox()
                        .focused(field, equals: .answer)
                        .task {
                            for _ in 0..<5 where field.wrappedValue != .answer {
                                field.wrappedValue = .answer
                                try? await Task.sleep(for: .milliseconds(30))
                            }
                        }
                        .onSubmit { saveAnswer(i) }
                        .onExitCommand { changing = nil }
                        .accessibilityLabel("Change assumption \(i + 1)")
                        .accessibilityIdentifier("desk-assumption-field")
                    Button("Save") { saveAnswer(i) }.loamPrimaryButton()
                    Button("Cancel") { changing = nil }.loamSecondaryButton()
                }
            } else if let current {
                Text("You want: \(current)").loamText(LoamTheme.bodyStyle).textSelection(.enabled)
                    .accessibilityIdentifier("desk-assumption-answer-\(i)")
            }
        }
        .padding(LoamTheme.space3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-assumption-\(i)")
    }

    private func saveAnswer(_ i: Int) {
        model.answerDeskAssumption(i, answer)
        changing = nil
        field.wrappedValue = nil
    }
}

/// The checks of the draft: a name and a shell command each. Edit turns the rows into fields.
private struct DeskChecks: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var editing = false

    var body: some View {
        let checks = model.desk.currentEdit.checks ?? run.doneWhen
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                ForEach(checks.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        TextField("Name", text: binding(i, \.name))
                            .textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                            .padding(.horizontal, 8).frame(width: 120, height: 26).loamFieldBox()
                            .focused(field, equals: .check)
                            .accessibilityIdentifier("desk-check-name-\(i)")
                        TextField("Command, such as go test ./...", text: binding(i, \.command))
                            .textFieldStyle(.plain).loamText(LoamTheme.codeStyle)
                            .padding(.horizontal, 8).frame(height: 26).loamFieldBox()
                            .focused(field, equals: .check)
                            .accessibilityIdentifier("desk-check-command-\(i)")
                        Button { model.editDeskChecks(checks.enumerated().filter { $0.offset != i }.map(\.element)) } label: {
                            Image(systemName: "minus.circle").foregroundStyle(LoamColor.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove the check")
                    }
                }
                HStack(spacing: LoamTheme.space3) {
                    Button("Add a check") { model.editDeskChecks(checks + [RunCheck(name: "", command: "")]) }
                        .buttonStyle(.plain).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    Button("Done") {
                        // A check needs a command. A check with no name takes its command as its name, as at Intake.
                        model.editDeskChecks(checks.compactMap { check in
                            let command = check.command.trimmingCharacters(in: .whitespaces)
                            guard !command.isEmpty else { return nil }
                            let name = check.name.trimmingCharacters(in: .whitespaces)
                            return RunCheck(name: name.isEmpty ? command : name, command: command)
                        })
                        editing = false
                        field.wrappedValue = nil
                    }
                    .loamSecondaryButton()
                    .accessibilityIdentifier("desk-checks-done")
                }
            } else {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                        Text(check.name).loamText(LoamTheme.bodyStyle).frame(width: 140, alignment: .leading).lineLimit(1)
                        Text(check.command).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !model.desk.rules.isEmpty {
                    let count = model.desk.rules.count
                    Text("+ \(count) rule \(count == 1 ? "check" : "checks")")
                        .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                        .help(model.desk.rules.map { "Rule: \($0.name)" }.joined(separator: "\n"))
                        .accessibilityIdentifier("desk-rule-checks")
                }
                HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space3) {
                    Text("And the work is committed").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                    Spacer()
                    Button("Edit") { editing = true }
                        .loamSecondaryButton()
                        .accessibilityIdentifier("desk-checks-edit")
                }
            }
        }
        .padding(LoamTheme.space3)
        .loamCard()
        .onChange(of: run.id) { editing = false }
        .accessibilityIdentifier("desk-checks")
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<RunCheck, String>) -> Binding<String> {
        Binding(
            get: {
                let checks = model.desk.currentEdit.checks ?? run.doneWhen
                return checks.indices.contains(i) ? checks[i][keyPath: key] : ""
            },
            set: { value in
                var checks = model.desk.currentEdit.checks ?? run.doneWhen
                guard checks.indices.contains(i) else { return }
                checks[i][keyPath: key] = value
                model.editDeskChecks(checks)
            })
    }
}

/// What happens when you approve: where the run works, its limits, and how it ends.
private struct DeskIfYouApprove: View {
    let model: AppModel
    let run: Run

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoamTheme.space3) {
                Text("If you approve").loamLabel()
                row("Worktree", "A new worktree and branch from \(base)")
                row("Tries", "Up to \(run.maxTries)")
                if let model = run.shape?.model, !model.isEmpty { row("Model", model) }
                if let source = run.source, source.kind == "linear" {
                    row("Linear", "\(source.key) moves to In Progress")
                }
                row("Setup", "The setup command of the repo runs first, if it has one")
                row("Ships when", "The checks pass and the work is committed. Loam then pushes the branch and opens the PR.")
            }
            .padding(LoamTheme.space4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-if-you-approve")
    }

    private var base: String {
        let base = run.shape?.base ?? ""
        return base.isEmpty ? "the default branch" : base
    }

    private func row(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            Text(text).loamText(LoamTheme.bodyStyle).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Approve and next, Ask Claude to change it, and Not now. Ask opens a field for your change.
private struct DeskShapeActions: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var asking = false
    @State private var change = ""

    var body: some View {
        let typing = field.wrappedValue != nil
        let drafting = model.desk.drafting.contains(run.id)
        let drafted = run.shape?.isDrafted == true
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            if asking {
                HStack(spacing: LoamTheme.space2) {
                    TextField("What should Claude change?", text: $change)
                        .textFieldStyle(.plain)
                        .loamText(LoamTheme.bodyStyle)
                        .padding(.horizontal, 9).frame(height: 28)
                        .loamFieldBox()
                        .focused(field, equals: .change)
                        .task {
                            for _ in 0..<5 where field.wrappedValue != .change {
                                field.wrappedValue = .change
                                try? await Task.sleep(for: .milliseconds(30))
                            }
                        }
                        .onSubmit { ask() }
                        .onExitCommand { cancelAsk() }
                        .accessibilityLabel("Change for Claude")
                        .accessibilityIdentifier("desk-change-field")
                    Button("Send to Claude") { ask() }
                        .loamPrimaryButton()
                        .disabled(change.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("desk-change-send")
                    Button("Cancel") { cancelAsk() }.loamSecondaryButton()
                }
            }
            HStack(spacing: LoamTheme.space3) {
                Button(model.desk.needsSetupApproval ? "Approve the setup and start" : "Approve and next") {
                    Task { await model.approveDeskRun() }
                }
                .loamPrimaryButton()
                .deskKey("a", typing: typing)
                .disabled(!drafted || drafting || model.desk.busy)
                .help("Start the run with the draft and your edits (A)")
                .accessibilityIdentifier("desk-approve")
                Button(drafted ? "Ask Claude to change it" : "Ask Claude again") {
                    change = ""
                    asking = true
                }
                .loamSecondaryButton()
                .deskKey("c", typing: typing)
                .disabled(drafting || asking)
                .help("Claude drafts the run again with your change (C)")
                .accessibilityIdentifier("desk-ask")
                Button("Not now") { Task { await model.notNowDeskRun() } }
                    .loamSecondaryButton()
                    .deskKey("n", typing: typing)
                    .disabled(drafting || model.desk.busy)
                    .help("Cancel the run. The issue stays open (N)")
                    .accessibilityIdentifier("desk-not-now")
                if model.desk.busy { ProgressView().controlSize(.small) }
                if let error = model.desk.error {
                    Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).lineLimit(2).textSelection(.enabled)
                        .accessibilityIdentifier("desk-error")
                } else {
                    Text("Nothing starts until you approve. J and K move through the desk.")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkMuted).lineLimit(2)
                }
                Spacer()
            }
        }
        .padding(.horizontal, LoamTheme.space6)
        .padding(.vertical, LoamTheme.space3)
        .onChange(of: run.id) { cancelAsk() }
    }

    private func ask() {
        let text = change
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        cancelAsk()
        Task { await model.redraftDeskRun(change: text) }
    }

    private func cancelAsk() {
        asking = false
        change = ""
        field.wrappedValue = nil
    }
}
