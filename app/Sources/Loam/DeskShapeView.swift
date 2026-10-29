import LoamKit
import SwiftUI

/// A run in Shaping at the desk (ticket 207): the queue at the left, Claude's draft of the goal, the checks, the
/// assumptions and the plan, and what an approval does. You edit the goal and the checks in place, keep or change
/// each assumption, and then approve the run, ask Claude to change the draft, or leave it for now. A, C and N do the
/// same while no field has the focus.
struct DeskShape: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DeskQueue(model: model)
                    .frame(width: 280)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        DeskShapeHeader(model: model, run: run)
                        DeskDraft(model: model, run: run, field: field)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                DeskIfYouApprove(model: model, run: run)
                    .frame(width: 320)
            }
            Divider()
            DeskShapeActions(model: model, run: run, field: field)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-shape")
    }
}

/// The station, plot and issue of the draft, when Claude shaped it and for which recurring run, and its title.
private struct DeskShapeHeader: View {
    let model: AppModel
    let run: Run

    var body: some View {
        let events = model.runStatus?.run.id == run.id ? model.runStatus?.events ?? [] : []
        VStack(alignment: .leading, spacing: 6) {
            Text(DeskContent.context(run, plotName: model.plots.first { $0.id == run.plotID }?.name ?? "",
                                     repoName: model.repoName(of: run), events: events,
                                     recurringTitle: model.desk.recurringTitle))
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .accessibilityIdentifier("desk-context")
            Text(run.title).loamText(LoamTheme.plotNameStyle).textSelection(.enabled)
                .accessibilityIdentifier("desk-item-title")
            RunGroupLinks(model: model, run: run)
        }
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
        VStack(alignment: .leading, spacing: 18) {
            if model.desk.drafting.contains(run.id) || (shape?.isDrafted != true && run.note == Self.draftingNote) {
                VStack(alignment: .leading, spacing: LoamTheme.space3) {
                    HStack(spacing: LoamTheme.space2) {
                        ProgressView().controlSize(.small)
                        Text("Claude is drafting the run. This takes a minute or two.")
                            .loamText(LoamTheme.bodyStyle, LoamColor.inkMuted)
                    }
                    DraftSteps(steps: model.runStatus?.run.id == run.id ? model.runStatus?.draftSteps ?? [] : [])
                }
                .accessibilityElement(children: .contain)
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
                        .padding(.horizontal, LoamTheme.space3).padding(.vertical, 9)
                        .background(LoamColor.horizonB, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.rule))
                        .focused(field, equals: .goal)
                        .onExitCommand { field.wrappedValue = nil }
                        .accessibilityLabel("Goal")
                        .accessibilityIdentifier("desk-goal")
                }
                DeskChecks(model: model, run: run, field: field)
                if let shape, !shape.assumptions.isEmpty {
                    assumptions(shape.assumptions, answers: edit.answers)
                }
                if let shape, !shape.followUps.isEmpty {
                    followUps(shape.followUps, dropped: edit.droppedFollowUps)
                }
                if let shape, !shape.plan.isEmpty || !shape.size.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        if !shape.plan.isEmpty {
                            plan(shape.plan)
                        }
                        if !shape.size.isEmpty {
                            VStack(alignment: .leading, spacing: LoamTheme.space2) {
                                Text("Size").deskHeading()
                                Text(shape.size).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("desk-size")
                        }
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
                Text(title).deskHeading()
                if edited { Text("Edited").loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
            }
            content()
        }
        .accessibilityElement(children: .contain)
    }

    private func plan(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            Text("Plan \u{00B7} \(steps.count == 1 ? "1 step" : "\(steps.count) steps") \u{00B7} Claude wrote this").deskHeading()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).monospacedDigit()
                            .frame(width: 18, alignment: .leading)
                        Text(step).loamText(LoamTheme.bodyStyle, LoamColor.inkMuted).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-plan")
    }

    /// The assumptions of the draft as one card, each with Keep and Change.
    private func assumptions(_ assumptions: [RunAssumption], answers: [Int: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoamTheme.space2) {
                Text("Claude made \(assumptions.count == 1 ? "1 assumption" : "\(assumptions.count) assumptions")")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(LoamColor.ink)
                if !answers.isEmpty { Text("Edited").loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
            }
            .padding(.bottom, 6)
            ForEach(Array(assumptions.enumerated()), id: \.offset) { i, assumption in
                if i > 0 { Rectangle().fill(LoamColor.inkHairline).frame(height: 1).padding(.vertical, LoamTheme.space2) }
                assumptionRow(i, assumption.text, answer: answers[i])
            }
        }
        .padding(.horizontal, 14).padding(.vertical, LoamTheme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-assumptions")
    }

    /// The follow-ups of the draft as one card: work that the draft leaves out on purpose. Loam files each kept one
    /// as an issue when you approve the run. Each shows its target, and you keep or drop it. To change the text,
    /// ask Claude to draft the run again.
    private func followUps(_ followUps: [RunFollowUp], dropped: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoamTheme.space2) {
                Text("Follow-ups \u{00B7} \(followUps.count == 1 ? "1 issue" : "\(followUps.count) issues") to file")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(LoamColor.ink)
                if !dropped.isEmpty { Text("Edited").loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
            }
            Text("Work that this run leaves out on purpose. Loam files each one when you approve.")
                .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .padding(.top, 2).padding(.bottom, LoamTheme.space3)
            ForEach(Array(followUps.enumerated()), id: \.offset) { i, followUp in
                if i > 0 { Rectangle().fill(LoamColor.inkHairline).frame(height: 1).padding(.vertical, LoamTheme.space2) }
                followUpRow(i, followUp, kept: !dropped.contains(i))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, LoamTheme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loamCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-followups")
    }

    /// One follow-up, with its title, its text, its target, and a toggle that keeps or drops it.
    private func followUpRow(_ i: Int, _ followUp: RunFollowUp, kept: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(followUp.title).loamText(LoamTheme.bodyStyle, kept ? LoamColor.ink : LoamColor.inkMuted)
                    .strikethrough(!kept)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !followUp.body.isEmpty {
                    Text(followUp.body).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Files in \(followUp.target.words)").loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                    .accessibilityIdentifier("desk-followup-target-\(i)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if kept {
                Label("Kept", systemImage: "checkmark")
                    .loamText(LoamTheme.captionStyle, LoamColor.moss)
                    .padding(.top, 5)
                    .accessibilityIdentifier("desk-followup-kept-\(i)")
                Button("Drop") { model.setDeskFollowUp(i, kept: false) }
                    .loamSecondaryButton()
                    .help("File no issue for this follow-up")
                    .accessibilityIdentifier("desk-followup-drop-\(i)")
            } else {
                Label("Dropped", systemImage: "xmark")
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .padding(.top, 5)
                    .accessibilityIdentifier("desk-followup-dropped-\(i)")
                Button("Keep") { model.setDeskFollowUp(i, kept: true) }
                    .loamSecondaryButton()
                    .help("File an issue for this follow-up when you approve")
                    .accessibilityIdentifier("desk-followup-keep-\(i)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-followup-\(i)")
    }

    /// One assumption, with Keep and Change. A changed assumption shows what you want in its place.
    private func assumptionRow(_ i: Int, _ text: String, answer current: String?) -> some View {
        VStack(alignment: .leading, spacing: LoamTheme.space2) {
            HStack(alignment: .top, spacing: 14) {
                Text(text).loamText(LoamTheme.bodyStyle, current == nil ? LoamColor.ink : LoamColor.inkMuted)
                    .strikethrough(current != nil)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if changing != i {
                    // A kept assumption says so. A disabled Keep button read as broken.
                    if current == nil {
                        Label("Kept", systemImage: "checkmark")
                            .loamText(LoamTheme.captionStyle, LoamColor.moss)
                            .padding(.top, 5)
                            .accessibilityIdentifier("desk-assumption-kept-\(i)")
                    } else {
                        Button("Keep") { model.answerDeskAssumption(i, "") }
                            .loamSecondaryButton()
                            .help("Keep the assumption as Claude drafted it")
                            .accessibilityIdentifier("desk-assumption-keep-\(i)")
                    }
                    Button("Change\u{2026}") {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-assumption-\(i)")
    }

    private func saveAnswer(_ i: Int) {
        model.answerDeskAssumption(i, answer)
        changing = nil
        field.wrappedValue = nil
    }
}

/// The steps that Claude takes while it drafts, such as "Read window/frame.go", as they come. The last step is the
/// one that Claude takes now. Only the last few show, so the card keeps its height.
private struct DraftSteps: View {
    let steps: [RunEvent]
    static let shown = 8

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if steps.count > Self.shown {
                    Text("\(steps.count - Self.shown) earlier \(steps.count - Self.shown == 1 ? "step" : "steps")")
                        .loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                }
                ForEach(steps.suffix(Self.shown)) { step in
                    let now = step.id == steps.last?.id
                    HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                        Image(systemName: now ? "ellipsis" : "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(now ? LoamColor.moss : LoamColor.inkFaint)
                            .frame(width: 12)
                        Text(step.detail)
                            .loamText(LoamTheme.captionStyle, now ? LoamColor.ink : LoamColor.inkMuted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.2), value: steps.last?.id)
            .padding(LoamTheme.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .loamCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("desk-draft-steps")
        }
    }
}

/// The checks of the draft, numbered: a name and a shell command each. Edit on a check turns it into fields.
private struct DeskChecks: View {
    let model: AppModel
    let run: Run
    let field: FocusState<DeskField?>.Binding
    @State private var editing: Int?

    var body: some View {
        let checks = model.desk.currentEdit.checks ?? run.doneWhen
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: LoamTheme.space2) {
                Text("Done when").deskHeading()
                Text(caption(checks.count)).loamText(LoamTheme.captionStyle, LoamColor.inkFaint)
                if model.desk.currentEdit.checks != nil { Text("Edited").loamText(LoamTheme.captionStyle, LoamColor.inkMuted) }
                Spacer()
                Button("Add a check") {
                    model.editDeskChecks(checks + [RunCheck(name: "", command: "")])
                    editing = checks.count
                }
                .buttonStyle(.plain).loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                .accessibilityIdentifier("desk-checks-add")
            }
            .padding(.bottom, 2)
            ForEach(checks.indices, id: \.self) { i in
                if editing == i { editor(i, checks) } else { row(i, checks[i]) }
            }
        }
        .onChange(of: run.id) { editing = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-checks")
    }

    private func caption(_ count: Int) -> String {
        "\(count == 1 ? "1 check" : "\(count) checks") \u{00B7} and the work is committed"
    }

    private func row(_ i: Int, _ check: RunCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            number(i)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).loamText(LoamTheme.bodyStyle)
                Text(check.command).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { editing = i } label: {
                Text("Edit").underline().loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            }
            .buttonStyle(.plain)
            .padding(.top, LoamTheme.space2)
            .accessibilityIdentifier("desk-check-edit-\(i)")
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(LoamColor.inkHairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-check-\(i)")
    }

    private func number(_ i: Int) -> some View {
        Text("\(i + 1)").font(.system(size: 11)).foregroundStyle(LoamColor.inkMuted)
            .frame(width: 20, height: 20)
            .background(LoamColor.inkFill, in: Circle())
            .overlay(Circle().strokeBorder(LoamColor.rule))
            .padding(.top, 1)
    }

    private func editor(_ i: Int, _ checks: [RunCheck]) -> some View {
        HStack(spacing: 6) {
            number(i)
            TextField("Name", text: binding(i, \.name))
                .textFieldStyle(.plain).loamText(LoamTheme.bodyStyle)
                .padding(.horizontal, 8).frame(width: 180, height: 26).loamFieldBox()
                .focused(field, equals: .check)
                .accessibilityIdentifier("desk-check-name-\(i)")
            TextField("Command, such as go test ./...", text: binding(i, \.command))
                .textFieldStyle(.plain).loamText(LoamTheme.codeStyle)
                .padding(.horizontal, 8).frame(height: 26).loamFieldBox()
                .focused(field, equals: .check)
                .onSubmit { done() }
                .accessibilityIdentifier("desk-check-command-\(i)")
            Button { remove(i, checks) } label: {
                Image(systemName: "minus.circle").foregroundStyle(LoamColor.inkMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the check")
            Button("Done") { done() }
                .loamSecondaryButton()
                .accessibilityIdentifier("desk-checks-done")
        }
        .padding(.vertical, 6)
    }

    private func remove(_ i: Int, _ checks: [RunCheck]) {
        model.editDeskChecks(checks.enumerated().filter { $0.offset != i }.map(\.element))
        editing = nil
        field.wrappedValue = nil
    }

    /// A check needs a command. A check with no name takes its command as its name, as at Intake.
    private func done() {
        let checks = model.desk.currentEdit.checks ?? run.doneWhen
        model.editDeskChecks(checks.compactMap { check in
            let command = check.command.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return nil }
            let name = check.name.trimmingCharacters(in: .whitespaces)
            return RunCheck(name: name.isEmpty ? command : name, command: command)
        })
        editing = nil
        field.wrappedValue = nil
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

/// What happens when you approve: the worktree and branch of the run, when it starts, its limits, the Linear
/// update, the setup command of the repo, and the gate.
private struct DeskIfYouApprove: View {
    let model: AppModel
    let run: Run

    var body: some View {
        let name = model.deskWorktreeName(run)
        let checks = model.desk.currentEdit.checks ?? run.doneWhen
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: LoamTheme.space2) {
                    Text("If you approve").deskHeading()
                    Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 9) {
                        row("Worktree", Text(name).loamText(LoamTheme.codeStyle))
                        row("Branch", VStack(alignment: .leading, spacing: 2) {
                            Text(name).loamText(LoamTheme.codeStyle)
                            Text("From \(base)").loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                        })
                        if let limits = model.desk.limits {
                            row("Starts", text(DeskContent.starts(limits: limits, runs: model.runs.filter { $0.id != run.id })))
                        }
                        row("Limits", text(DeskContent.limits(model.desk.limits, maxTries: run.maxTries)))
                        if let shapeModel = run.shape?.model, !shapeModel.isEmpty { row("Model", text(shapeModel)) }
                        if keptFollowUps > 0 {
                            row("Follow-ups", text("Files \(keptFollowUps == 1 ? "1 issue" : "\(keptFollowUps) issues") for the work it leaves out"))
                                .accessibilityIdentifier("desk-approve-followups")
                        }
                        if let source = run.source, source.kind == "linear", model.desk.linearUpdates?.inProgress == true {
                            row("Linear", text("\(source.key) moves to In Progress when the run starts"))
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("desk-approve-rows")
                if let setup = model.desk.setup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Setup in the worktree").deskHeading()
                        Text(setup).loamText(LoamTheme.codeStyle, LoamColor.inkMuted).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, LoamTheme.space2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LoamColor.inkHairline))
                        Text("You approve it now, because nobody will be there to approve it later. Loam asks again if the command changes.")
                            .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("desk-setup")
                }
                VStack(alignment: .leading, spacing: LoamTheme.space2) {
                    Text("The gate").deskHeading()
                    DeskWrap(spacing: 6) {
                        ForEach(Array(checks.enumerated()), id: \.offset) { _, check in chip(check.command).help(check.command) }
                        if !model.desk.rules.isEmpty {
                            let count = model.desk.rules.count
                            chip("+ \(count) rule \(count == 1 ? "check" : "checks")")
                                .help(model.desk.rules.map { "Rule: \($0.name)" }.joined(separator: "\n"))
                                .accessibilityIdentifier("desk-rule-checks")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("desk-gate")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk-if-you-approve")
    }

    /// The follow-ups that approve files as issues: the ones that you did not drop.
    private var keptFollowUps: Int {
        (run.shape?.followUps.count ?? 0) - model.desk.currentEdit.droppedFollowUps.count
    }

    private var base: String {
        let base = run.shape?.base ?? ""
        return base.isEmpty ? "the default branch" : base
    }

    private func text(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(LoamColor.ink).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, _ value: some View) -> some View {
        GridRow {
            Text(title).font(.system(size: 12)).foregroundStyle(LoamColor.inkMuted).frame(width: 76, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String) -> some View {
        let code = LoamTheme.font(LoamTheme.codeStyle)
        return Text(text).font(Font(NSFont(descriptor: code.fontDescriptor, size: 10.5) ?? code))
            .foregroundStyle(LoamColor.inkMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6).frame(height: 18)
            .background(LoamColor.inkFill, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(LoamColor.inkHairline))
    }
}

/// A row of views that wraps to the next line when the width runs out, aligned to the leading edge. Each view gets
/// the line width as its proposal and is never wider than it, so a view that cannot shrink is cut at the line.
private struct DeskWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? .infinity), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// The size of a view on a line of the width, or its ideal size when the width is open.
    private func size(of subview: LayoutSubview, width: CGFloat?) -> CGSize {
        let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(size.width, width ?? .infinity), height: size.height)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> [Line] {
        var lines = [Line()]
        for index in subviews.indices {
            let size = size(of: subviews[index], width: width)
            let last = lines.count - 1
            if !lines[last].indices.isEmpty, lines[last].width + spacing + size.width > width ?? .infinity { lines.append(Line()) }
            let line = lines.count - 1
            lines[line].width = lines[line].indices.isEmpty ? size.width : lines[line].width + spacing + size.width
            lines[line].height = max(lines[line].height, size.height)
            lines[line].indices.append(index)
        }
        return lines
    }
}

/// Approve and next, Ask Claude to change it, and Not now, with the keys that move through the desk. Ask opens a
/// field for your change.
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
                .padding(.top, LoamTheme.space3)
            }
            HStack(spacing: 10) {
                Button { Task { await model.approveDeskRun() } } label: {
                    DeskKeyLabel(title: model.desk.needsSetupApproval ? "Approve the setup and start" : "Approve and next",
                                 key: "A", primary: true)
                }
                .loamPrimaryButton()
                .deskKey("a", typing: typing)
                .disabled(!drafted || drafting || model.desk.busy)
                .help("Start the run with the draft and your edits (A)")
                .accessibilityIdentifier("desk-approve")
                Button {
                    change = ""
                    asking = true
                } label: {
                    DeskKeyLabel(title: drafted ? "Ask Claude to change it" : "Ask Claude again", key: "C")
                }
                .loamSecondaryButton()
                .deskKey("c", typing: typing)
                .disabled(drafting || asking)
                .help("Claude drafts the run again with your change (C)")
                .accessibilityIdentifier("desk-ask")
                Button { Task { await model.notNowDeskRun() } } label: { DeskKeyLabel(title: "Not now", key: "N") }
                    .loamSecondaryButton()
                    .deskKey("n", typing: typing)
                    .disabled(drafting || model.desk.busy)
                    .help("Cancel the run. The issue stays open (N)")
                    .accessibilityIdentifier("desk-not-now")
                if model.desk.busy { ProgressView().controlSize(.small) }
                if let error = model.desk.error {
                    Text(error).loamText(LoamTheme.captionStyle, LoamColor.rust).lineLimit(2).textSelection(.enabled)
                        .accessibilityIdentifier("desk-error")
                }
                Spacer()
                DeskNavHints(model: model, typing: typing)
            }
            .frame(height: 64)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
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
