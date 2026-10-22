import Foundation
import Testing

@testable import LoamKit

/// Ticket 110: Send to session. The worktrees come from the `worktree_list_stages` fixture (made-up
/// example/widgets data, all in the plot `plotaaaaab`).
private func stageRows() throws -> [WorktreeStatus] {
    try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
}

private func row(_ stage: WorktreeStage) throws -> WorktreeStatus {
    try #require(try stageRows().first { $0.stage == stage })
}

// MARK: The prompts

/// One prompt for each stage that a session can fix, with the values of the PR. The words are the ones of the ticket.
@Suite struct FixPromptTests {
    /// The PR of a stage of the fixture as PR #139 of the branch native-panel, as the ticket has it.
    func pr(_ stage: WorktreeStage) throws -> PullRequest {
        var pr = try #require(try row(stage).pr)
        pr.number = 139
        pr.head = "native-panel"
        return pr
    }

    /// The failed check of the fixture with other names.
    func checks(_ names: [String]) throws -> [PRCheck] {
        let check = try #require(try row(.checksFailed).pr?.failedChecks.first)
        return names.map { var named = check; named.name = $0; return named }
    }

    @Test func checksFailedNamesTheFailedChecksAndTheCommand() throws {
        var pr = try pr(.checksFailed)
        pr.failedChecks = try checks(["lint / swiftformat", "test / macos-26"])
        #expect(FixPrompt(.failures, pr: pr).text
            == "Checks failed on #139: lint / swiftformat, test / macos-26. Run `gh pr checks 139`, read the failing logs, fix them, and push.")
    }

    @Test func changesRequestedCountsTheReviewComments() throws {
        var pr = try pr(.changesRequested)
        #expect(pr.comments == 3)
        #expect(FixPrompt(.review, pr: pr).text
            == "PR #139 has changes requested, with 3 review comments. Run `gh pr view 139 --comments`, address each comment, and push.")
        pr.comments = 1
        #expect(FixPrompt(.review, pr: pr).text.hasPrefix("PR #139 has changes requested, with 1 review comment. Run"))
        // A review with no open thread still has its own words, so the command is the same.
        pr.comments = 0
        #expect(FixPrompt(.review, pr: pr).text == "PR #139 has changes requested. Run `gh pr view 139 --comments`, address each comment, and push.")
    }

    @Test func conflictsNameTheBaseAndTheBranch() throws {
        #expect(FixPrompt(.conflicts, pr: try pr(.conflicts)).text
            == "PR #139 conflicts with main. Merge origin/main into native-panel, resolve the conflicts, run the tests, and push.")
        var other = try pr(.conflicts)
        other.base = "release"
        #expect(FixPrompt(.conflicts, pr: other).text.hasPrefix("PR #139 conflicts with release. Merge origin/release into native-panel,"))
    }

    @Test func aPromptNamesFiveFailedChecksAndCountsTheRest() throws {
        var pr = try pr(.checksFailed)
        pr.failedChecks = try checks((1...8).map { "job-\($0)" })
        #expect(FixPrompt(.failures, pr: pr).text.hasPrefix("Checks failed on #139: job-1, job-2, job-3, job-4, job-5, and 3 more. Run"))
        pr.failedChecks = try checks((1...6).map { "job-\($0)" })
        #expect(FixPrompt(.failures, pr: pr).text.hasPrefix("Checks failed on #139: job-1, job-2, job-3, job-4, job-5, and 1 more. Run"))
        pr.failedChecks = try checks((1...FixPrompt.namedChecks).map { "job-\($0)" })
        #expect(FixPrompt(.failures, pr: pr).text.hasPrefix("Checks failed on #139: job-1, job-2, job-3, job-4, job-5. Run"))
    }

    @Test func checksFailedWithNoNamedCheckStillNamesTheCommand() throws {
        var pr = try pr(.checksFailed)
        pr.failedChecks = []
        #expect(FixPrompt(.failures, pr: pr).text == "Checks failed on #139. Run `gh pr checks 139`, read the failing logs, fix them, and push.")
    }

    /// A PR from a fork names its own checks. A control character must not act as a key, a line break as Return, or a
    /// direction mark hide the words.
    @Test func aNameWithAControlCharacterOrALineBreakStaysOneLine() throws {
        var pr = try pr(.checksFailed)
        pr.failedChecks = try checks(["lint\n/ swift\tformat", "a\u{1B}[201~b\u{7}", "\u{202E}test  /\r\nmacos"])
        let text = FixPrompt(.failures, pr: pr).text
        #expect(text.hasPrefix("Checks failed on #139: lint / swift format, a [201~b, test / macos. Run"))
        #expect(throws: Never.self) { try PaneText.withoutReturn(text) }
    }

    /// Characters that show nothing could hide words from you in the prompt: tag characters, zero-width
    /// characters, a byte order mark, a private use or an unassigned code point.
    @Test func aNameLosesTheCharactersThatShowNothing() throws {
        var pr = try pr(.checksFailed)
        let tags = "\u{E0001}\u{E0069}\u{E0067}\u{E006E}\u{E007F}"
        pr.failedChecks = try checks(["li\u{200B}nt\(tags)", "\u{FEFF}te\u{2060}st\u{200D}", "a\u{E000}b\u{FFFF}\u{E0FFF}"])
        #expect(FixPrompt(.failures, pr: pr).text.hasPrefix("Checks failed on #139: lint, test, ab. Run"))
        #expect(FixPrompt.oneLine("\u{202E}\u{200B}\u{FEFF}") == "")
    }

    /// A check name can be as long as its job wants. The prompt cuts it at 80 characters. A branch name stays whole,
    /// because the conflicts prompt tells the session to merge it.
    @Test func aLongCheckNameIsCutAndABranchNameIsNot() throws {
        var pr = try pr(.checksFailed)
        let long = String(repeating: "x", count: 200)
        pr.failedChecks = try checks([long, "lint"])
        let cut = String(repeating: "x", count: FixPrompt.longestCheckName - 1) + "\u{2026}"
        #expect(cut.count == 80)
        #expect(FixPrompt(.failures, pr: pr).text.hasPrefix("Checks failed on #139: \(cut), lint. Run"))
        var conflicts = try self.pr(.conflicts)
        conflicts.head = long + "\u{200B}\n"
        conflicts.base = "rel\u{E0001}ease"
        #expect(FixPrompt(.conflicts, pr: conflicts).text
            == "PR #139 conflicts with release. Merge origin/release into \(long), resolve the conflicts, run the tests, and push.")
    }

    @Test func eachPromptIsOneLineThatLoamCanType() throws {
        for kind in FixPrompt.Kind.allCases {
            let stage: WorktreeStage = switch kind {
            case .failures: .checksFailed
            case .review: .changesRequested
            case .conflicts: .conflicts
            }
            let text = FixPrompt(kind, pr: try pr(stage)).text
            #expect(try PaneText.withoutReturn(text) == text, "\(kind)")
        }
    }

    @Test func theStageGivesTheKind() throws {
        for status in try stageRows() {
            let expected: FixPrompt.Kind? = switch status.stage {
            case .checksFailed: .failures
            case .changesRequested: .review
            case .conflicts: .conflicts
            default: nil
            }
            #expect(FixPrompt(status)?.kind == expected, "\(String(describing: status.stage))")
        }
        var noPR = try row(.checksFailed)
        noPR.pr = nil
        #expect(FixPrompt(noPR) == nil)
    }

    @Test func eachKindHasItsButton() {
        #expect(FixPrompt.Kind.allCases.map(\.action.title) == ["Send failures to session", "Send review to session", "Send conflicts to session"])
    }
}

// MARK: The model

/// What the model typed into a pane, copied, said in the toast, and gave the keys to.
@MainActor final class SendRecord {
    var typed: [(pane: PaneID, text: String)] = []
    var copied: [String] = []
    var toasts: [String] = []
    var keys: [PaneID] = []
}

/// The session that gets the prompt, the rule for when Loam may type, and the model that types, copies, or starts a
/// session.
@MainActor
@Suite struct SendToSessionTests {
    let plotID = "plotaaaaab"
    /// native-panel, #16, Checks failed.
    let failed = "wtreaaaaah"
    /// rename-users, #15, Changes requested.
    let review = "wtreaaaaag"
    /// new-api, #14, Conflicts.
    let conflicts = "wtreaaaaaf"

    /// The rows that the fake `loam` prints, for each rig.
    static let rowsFile = "rows.json"

    /// A model with the fixture rows and a fake `loam` that prints them for every list. The terminal of each pane
    /// takes text at once.
    func rig() async throws -> (model: AppModel, record: SendRecord) {
        let (model, record, _) = try await rigWithRows()
        return (model, record)
    }

    /// The rig, and the file of rows that the fake `loam` prints, so a test can change the rows.
    func rigWithRows() async throws -> (model: AppModel, record: SendRecord, rows: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = dir.appendingPathComponent(Self.rowsFile)
        try Fixtures.data("worktree_list_stages").write(to: rows)
        try FakeScript.install("#!/bin/sh\ncat '\(rows.path)'\n", at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        await model.reloadWorktrees()
        let record = SendRecord()
        model.typeIntoPane = { pane, text in record.typed.append((pane, text)); return true }
        model.copyText = { record.copied.append($0) }
        model.onToast = { record.toasts.append($0) }
        model.onPromptTyped = { record.keys.append($0) }
        return (model, record, rows)
    }

    func worktree(_ id: String, in model: AppModel) throws -> Worktree {
        try #require(model.worktreeStatus(id)?.worktree)
    }

    /// Opens a pane in the worktree. A session pane starts, so it is idle.
    @discardableResult
    func open(_ kind: PaneSpec.Kind = .session, in id: String, _ model: AppModel, title: String? = nil) throws -> PaneID {
        model.openWorktreePane(try worktree(id, in: model), kind: kind)
        let pane = try #require(model.workspace.focusedPane)
        if kind == .session { send("SessionStart", to: pane, model, source: "startup") }
        if let title { model.setTerminalTitle(title, of: pane) }
        return pane
    }

    func send(_ name: String, to pane: PaneID, _ model: AppModel, source: String? = nil) {
        model.apply(paneEvent(name, model.workspace.session(of: pane)?.sessionID ?? "", source: source), to: pane)
    }

    func prompt(_ id: String, _ model: AppModel) throws -> String {
        try #require(model.worktreeStatus(id).flatMap(FixPrompt.init)?.text)
    }

    // MARK: The session that gets the prompt

    @Test func theTargetIsTheSessionPaneOfTheWorktree() async throws {
        let (model, _) = try await rig()
        try open(.shell, in: failed, model)
        try open(in: review, model)
        #expect(model.sendPlan(for: failed)?.step == .start, "a shell pane or a session of another worktree is no target")
        let session = try open(in: failed, model)
        #expect(model.sendPlan(for: failed)?.step == .type(session))
    }

    @Test func ofTwoSessionsTheTargetIsTheOneYouFocusedLast() async throws {
        let (model, _) = try await rig()
        let first = try open(in: failed, model)
        let second = try open(in: failed, model)
        #expect(model.sendPlan(for: failed)?.step == .type(second))
        try open(.shell, in: review, model)  // A pane of another worktree does not change the choice.
        #expect(model.sendPlan(for: failed)?.step == .type(second))
        model.focus(first)
        #expect(model.sendPlan(for: failed)?.step == .type(first))
        model.closePane(first)
        #expect(model.sendPlan(for: failed)?.step == .type(second))
    }

    @Test func aSessionThatEndedIsNoTarget() async throws {
        let (model, _) = try await rig()
        let pane = try open(in: failed, model)
        send("SessionEnd", to: pane, model)
        #expect(model.sendPlan(for: failed)?.step == .start)
        let other = try open(in: failed, model)
        model.paneExited(other)
        #expect(model.sendPlan(for: failed)?.step == .start)
    }

    @Test func aStageWithNoPromptHasNoPlan() async throws {
        let (model, _) = try await rig()
        #expect(model.sendPlan(for: "wtreaaaaao") == nil)  // Ready to merge.
        #expect(model.sendPlan(for: "nope") == nil)
        #expect(model.sendPlan(for: conflicts)?.prompt.kind == .conflicts)
    }

    // MARK: The rule for when Loam may type

    /// The rule on its own, for each state of a pane.
    @Test func theRuleForEachPaneState() {
        let pane = PaneID()
        let expected: [PaneState: SendPlan.Step] = [
            .running: .copy(.starting), .idle: .type(pane), .working: .copy(.busy), .needsYou: .copy(.busy), .ended: .start,
        ]
        for state in [PaneState.running, .idle, .working, .needsYou, .ended] {
            #expect(SendPlan.step(for: pane, session: PaneSession(state: state), prompt: "Fix it.") == expected[state], "\(state)")
        }
        var typed = PaneSession(state: .idle)
        typed.typedSinceSubmit = true
        #expect(SendPlan.step(for: pane, session: typed, prompt: "Fix it.") == .copy(.typed))
        var prompted = PaneSession(state: .idle)
        prompted.loamPrompt = "Fix it."
        #expect(SendPlan.step(for: pane, session: prompted, prompt: "Fix it.") == .type(pane))
        #expect(SendPlan.step(for: pane, session: prompted, prompt: "Fix the other thing.") == .copy(.prompted))
    }

    /// A submit takes the input, so the keys before it do not count after it. An event for another session
    /// changes nothing.
    @Test func theSessionCountsTheKeysUntilASubmit() {
        var session = PaneSession(sessionID: "s1", state: .idle, started: true)
        session.input()
        session.loamPrompt = "Fix it."
        #expect(session.typedSinceSubmit)
        session.apply(paneEvent("UserPromptSubmit", "other"))
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it.")
        session.apply(paneEvent("UserPromptSubmit", "s1"))
        #expect(!session.typedSinceSubmit && session.loamPrompt == nil)
    }

    /// Claude Code keeps a draft that you type during a turn and do not send. So the keys between a submit and
    /// the Stop still count after the Stop.
    @Test func theKeysOfATurnStillCountAfterItsStop() {
        var session = PaneSession(sessionID: "s1", state: .idle, started: true)
        session.apply(paneEvent("UserPromptSubmit", "s1"))
        session.input()
        session.apply(paneEvent("Stop", "s1"))
        #expect(session.state == .idle && session.typedSinceSubmit)
    }

    /// A turn that Claude Code starts by itself sends no `UserPromptSubmit`. Its Stop keeps the input as it is.
    @Test func aTurnWithNoSubmitKeepsTheInput() {
        var session = PaneSession(sessionID: "s1", state: .idle, started: true)
        session.input()
        session.loamPrompt = "Fix it."
        session.apply(paneEvent("PostToolUse", "s1"))
        session.apply(paneEvent("Stop", "s1"))
        #expect(session.state == .idle)
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it.")
    }

    @Test func loamTypesOnlyIntoAnIdleSession() async throws {
        let (model, _) = try await rig()
        model.openWorktreePane(try worktree(failed, in: model))
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.workspace.state(of: pane) == .running)
        #expect(model.sendPlan(for: failed)?.step == .copy(.starting))
        send("SessionStart", to: pane, model, source: "startup")
        #expect(model.workspace.state(of: pane) == .idle)
        #expect(model.sendPlan(for: failed)?.step == .type(pane))
        send("UserPromptSubmit", to: pane, model)
        #expect(model.workspace.state(of: pane) == .working)
        #expect(model.sendPlan(for: failed)?.step == .copy(.busy))
        model.apply(paneEvent("Notification", model.workspace.session(of: pane)!.sessionID!, notification: "elicitation_dialog"), to: pane)
        #expect(model.workspace.state(of: pane) == .needsYou)
        #expect(model.sendPlan(for: failed)?.step == .copy(.busy))
        send("Stop", to: pane, model)
        #expect(model.sendPlan(for: failed)?.step == .type(pane))
    }

    @Test func aKeyInTheTurnBlocksAfterTheStop() async throws {
        let (model, _) = try await rig()
        let pane = try open(in: failed, model)
        model.input(in: pane)
        #expect(model.sendPlan(for: failed)?.step == .copy(.typed))
        send("UserPromptSubmit", to: pane, model)
        model.input(in: pane)
        send("Stop", to: pane, model)
        #expect(model.sendPlan(for: failed)?.step == .copy(.typed))
        send("UserPromptSubmit", to: pane, model)
        send("Stop", to: pane, model)
        #expect(model.sendPlan(for: failed)?.step == .type(pane))
    }

    /// An arrow key can recall a prompt and Tab can complete one. A paste or a drop puts text in. Each counts as
    /// input until a submit, and none of them answers a session that needs you.
    @Test func anInputDoesNotAnswerASessionThatNeedsYou() async throws {
        let (model, _) = try await rig()
        let pane = try open(in: failed, model)
        send("UserPromptSubmit", to: pane, model)
        model.apply(paneEvent("Notification", model.workspace.session(of: pane)!.sessionID!, notification: "elicitation_dialog"), to: pane)
        model.input(in: pane)
        #expect(model.workspace.state(of: pane) == .needsYou)
        #expect(model.workspace.session(of: pane)?.typedSinceSubmit == true)
    }

    /// `/clear` and a resume start with an empty input. A compact can come in the middle of a turn, while you type.
    @Test func aNewSessionInThePaneForgetsTheKeysAndACompactKeepsThem() async throws {
        let (model, _) = try await rig()
        let pane = try open(in: failed, model)
        model.input(in: pane)
        send("SessionStart", to: pane, model, source: "compact")
        #expect(model.sendPlan(for: failed)?.step == .copy(.typed))
        send("SessionEnd", to: pane, model)
        model.apply(paneEvent("SessionStart", "next-session", source: "clear"), to: pane)
        #expect(model.sendPlan(for: failed)?.step == .type(pane))
    }

    @Test func theWordsOfEachStep() async throws {
        let (model, _) = try await rig()
        let pane = try open(in: failed, model, title: "\u{2733} Native panel spacing")
        let plan = try #require(model.sendPlan(for: failed))
        #expect(plan.buttonTitle == "Send failures to session")
        #expect(plan.paneName == "\u{2733} Native panel spacing")
        #expect(plan.typeTarget == "\u{2733} Native panel spacing")
        #expect(plan.footnote == "Loam types the prompt into the session. You press Return.")
        #expect(plan.toast == "Loam typed the failures into \u{2733} Native panel spacing. Press Return to send.")
        send("UserPromptSubmit", to: pane, model)
        let busy = try #require(model.sendPlan(for: failed))
        #expect(busy.buttonTitle == "Copy prompt")
        #expect(busy.typeTarget == nil && busy.toast == nil)
        #expect(busy.footnote == "The session is busy. Copy the prompt and send it when the turn ends.")
        send("Stop", to: pane, model)
        model.input(in: pane)
        #expect(model.sendPlan(for: failed)?.footnote == "You have typed in this session. Loam does not type over your text.")
        let start = try #require(model.sendPlan(for: review))
        #expect(start.buttonTitle == "Start session with prompt")
        #expect(start.paneName == nil)
        #expect(start.footnote == "No session runs in this worktree. Loam starts one and types the review prompt. You press Return.")
        #expect(SendPlan.toast(.conflicts, into: "\u{2733} New API") == "Loam typed the conflicts into \u{2733} New API. Press Return to send.")
        #expect(start.toast == nil)
    }

    // MARK: Send

    @Test func anIdleSessionGetsThePromptTheFocusAndAToast() async throws {
        let (model, record) = try await rig()
        let pane = try open(in: failed, model, title: "\u{2733} Native panel spacing")
        let shell = try open(.shell, in: review, model)
        #expect(model.workspace.focusedPane == shell)
        #expect(model.openPullRequest(failed))
        let plan = model.sendToSession(failed)
        #expect(plan?.step == .type(pane))
        #expect(record.typed.map(\.pane) == [pane])
        #expect(record.typed.map(\.text) == [try prompt(failed, model)])
        #expect(model.workspace.focusedPane == pane)
        #expect(record.keys == [pane])
        #expect(!model.prPopover.isOpen)
        #expect(record.toasts == ["Loam typed the failures into \u{2733} Native panel spacing. Press Return to send."])
        #expect(record.copied.isEmpty)
    }

    /// The prompt waits in the input until you press Return. A second Send does not type it again.
    @Test func loamTypesThePromptOnce() async throws {
        let (model, record) = try await rig()
        let pane = try open(in: failed, model)
        model.sendToSession(failed)
        try open(.shell, in: review, model)
        #expect(model.sendPlan(for: failed)?.step == .type(pane))
        model.sendToSession(failed)
        #expect(record.typed.count == 1)
        #expect(model.workspace.focusedPane == pane)
        #expect(record.toasts.count == 2)
        // Your Return sends it. The submit takes the input, so Loam can type again after the turn.
        model.input(in: pane)
        send("UserPromptSubmit", to: pane, model)
        send("Stop", to: pane, model)
        model.sendToSession(failed)
        #expect(record.typed.count == 2)
    }

    /// A check that fails later changes the prompt. The old prompt still waits in the input.
    @Test func anotherPromptFromLoamIsNotTypedOver() async throws {
        let (model, record, rows) = try await rigWithRows()
        try open(in: failed, model)
        model.sendToSession(failed)
        var list = try JSONDecoder().decode([WorktreeStatus].self, from: Data(contentsOf: rows))
        let i = try #require(list.firstIndex { $0.worktree.id == failed })
        var check = try #require(list[i].pr?.failedChecks.first)
        check.name = "test / linux"
        list[i].pr?.failedChecks.append(check)
        try JSONEncoder().encode(list).write(to: rows)
        await model.reloadWorktrees()
        #expect(model.sendPlan(for: failed)?.prompt.text.contains("test / linux") == true)
        let plan = try #require(model.sendPlan(for: failed))
        #expect(plan.step == .copy(.prompted))
        #expect(plan.footnote == "This session has a prompt from Loam that you have not sent. Loam does not type over it.")
        #expect(record.typed.count == 1)
    }

    @Test func aBusySessionCopiesThePromptAndThePopoverSaysSo() async throws {
        let (model, record) = try await rig()
        let pane = try open(in: failed, model)
        send("UserPromptSubmit", to: pane, model)
        #expect(model.openPullRequest(failed))
        #expect(model.sendToSession(failed)?.step == .copy(.busy))
        #expect(record.copied == [try prompt(failed, model)])
        #expect(record.typed.isEmpty && record.toasts.isEmpty)
        #expect(model.prPopover.isOpen && model.prPopover.note == "Copied the prompt.")
    }

    @Test func noSessionStartsOneAndTypesAfterItsSessionStart() async throws {
        let (model, record) = try await rig()
        try open(.shell, in: failed, model)
        let before = Set(model.workspace.allPaneIDs)
        #expect(model.openPullRequest(review))
        #expect(model.sendToSession(review)?.step == .start)
        #expect(!model.prPopover.isOpen)
        let pane = try #require(model.workspace.focusedPane)
        #expect(!before.contains(pane))
        let spec = try #require(model.workspace.spec(of: pane))
        #expect(spec.kind == .session && spec.worktree?.id == review && spec.space == .plot(plotID))
        #expect(record.typed.isEmpty)
        // The session runs the setup question first, and you answer it. Those keys are not in the input of Claude Code.
        model.input(in: pane)
        send("SessionStart", to: pane, model, source: "startup")
        #expect(record.typed.map(\.pane) == [pane])
        #expect(record.typed.map(\.text) == [try prompt(review, model)])
        #expect(record.toasts == ["Loam typed the review into the new session. Press Return to send."])
        // A later SessionStart, such as /clear, types nothing more.
        send("SessionEnd", to: pane, model)
        model.apply(paneEvent("SessionStart", "next-session", source: "clear"), to: pane)
        #expect(record.typed.count == 1)
    }

    /// The pane can still show the setup question. Loam does not open the popover over it, because Return would then
    /// run Copy prompt. A toast says what happened, and a late SessionStart types nothing.
    @Test func aSessionThatDoesNotStartInTimeGetsNoPromptAndAToast() async throws {
        let (model, record) = try await rig()
        model.sessionStartWait = .milliseconds(50)
        #expect(model.sendToSession(review)?.step == .start)
        let pane = try #require(model.workspace.focusedPane)
        await waitUntil("the toast shows") { !record.toasts.isEmpty }
        #expect(record.toasts == ["The session did not start in 30 seconds. Loam did not type the prompt."])
        #expect(!model.prPopover.isOpen)
        #expect(model.workspace.focusedPane == pane)
        #expect(model.sendPlan(for: review)?.step == .copy(.starting))
        send("SessionStart", to: pane, model, source: "startup")
        #expect(record.typed.isEmpty)
        #expect(model.sendPlan(for: review)?.step == .type(pane))
    }

    /// A second click while the first session waits copies the prompt. It starts no second session, and the first
    /// session still gets the prompt once.
    @Test func aSecondStartClickWhileTheSessionWaitsCopiesThePrompt() async throws {
        let (model, record) = try await rig()
        #expect(model.sendToSession(review)?.step == .start)
        let pane = try #require(model.workspace.focusedPane)
        let panes = model.workspace.allPaneIDs
        #expect(model.openPullRequest(review))
        #expect(model.sendToSession(review)?.step == .copy(.starting))
        #expect(model.workspace.allPaneIDs == panes)
        #expect(record.copied == [try prompt(review, model)])
        send("SessionStart", to: pane, model, source: "startup")
        #expect(record.typed.map(\.pane) == [pane])
    }

    /// The wait of a pane that closes stops, so it shows no toast. The wait of the next session still runs out.
    @Test func aSessionThatClosesBeforeItStartsGetsNothing() async throws {
        let (model, record) = try await rig()
        model.sessionStartWait = .milliseconds(50)
        model.sendToSession(review)
        let closed = try #require(model.workspace.focusedPane)
        model.closePane(closed)
        model.sendToSession(review)
        #expect(model.workspace.focusedPane != closed)
        await waitUntil("the toast of the next session shows") { !record.toasts.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(record.toasts.count == 1)
        #expect(record.typed.isEmpty)
    }

    /// The Worktree actions menu and ⌘J send the failures too. When Loam cannot type, the popover opens, so you see why.
    @Test func theMenusSendOrOpenThePopover() async throws {
        let (model, record) = try await rig()
        let pane = try open(in: failed, model)
        model.sendFromMenu(failed)
        #expect(record.typed.count == 1)
        model.input(in: pane)
        model.sendFromMenu(failed)
        #expect(model.prPopover.worktreeID == failed)
        #expect(record.copied.isEmpty && record.typed.count == 1)
    }

    @Test func onlyChecksFailedHasTheSendFailuresItem() async throws {
        let (model, _) = try await rig()
        #expect(model.canSendFailures(failed))
        #expect(!model.canSendFailures(review))
        #expect(!model.canSendFailures(conflicts))
        #expect(!model.canSendFailures("wtreaaaaao"))
    }

    @Test func theToastOfTheActionBarShowsTheLine() {
        let bar = ActionBarModel()
        bar.show("Loam typed the failures into \u{2733} Native panel spacing. Press Return to send.")
        #expect(bar.trailing == .toast("Loam typed the failures into \u{2733} Native panel spacing. Press Return to send."))
        let id = bar.toastID
        bar.show("Loam typed the review into \u{2733} Rename users. Press Return to send.")
        bar.clearToast(id: id)
        #expect(bar.toast != nil, "the timer of the first toast does not clear the second")
        bar.clearToast(id: bar.toastID)
        #expect(bar.toast == nil)
    }
}

@MainActor private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), "\(what) did not happen")
}
