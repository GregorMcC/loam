import Foundation
import Testing

@testable import LoamKit

/// A fake `loam` that prints `output` for every call and records the arguments.
private func fakePrinting(_ output: Data) throws -> FakeLoam {
    let fake = try FakeLoam([("", 0)])
    let file = fake.dir.appendingPathComponent("output.json")
    try output.write(to: file)
    try """
    echo "$@" >> '\(fake.argsLog.path)'
    cat '\(file.path)'
    """.write(to: fake.script, atomically: true, encoding: .utf8)
    return fake
}

/// The fixture `worktree_list_stages` with `pr_note` set on every row.
private func stageRows(note: String) throws -> Data {
    var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
    for index in rows.indices { rows[index]["pr_note"] = note }
    return try JSONSerialization.data(withJSONObject: rows)
}

private func plot(_ id: String) -> PlotSummary {
    PlotSummary(id: id, name: "Plot \(id)", what: "", createdAt: "2026-01-01T00:00:00Z")
}

private func refreshCalls(_ fake: FakeLoam) -> [String] { fake.args().filter { $0.contains("--refresh") } }

/// Waits until `count` refresh calls ran. Fails the test after 5 s.
@MainActor private func waitForRefreshes(_ fake: FakeLoam, _ count: Int) async {
    let deadline = Date().addingTimeInterval(5)
    while refreshCalls(fake).count < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(refreshCalls(fake).count >= count, "\(refreshCalls(fake).count) refreshes ran, not \(count)")
}

/// Waits until `condition` holds. Fails the test after 5 s.
@MainActor private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(condition(), "\(what) did not happen")
}

/// A value that a closure can change.
@MainActor final class ShipBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Waits long enough for a call that must not come.
private func settle() async { try? await Task.sleep(for: .milliseconds(200)) }

/// Ticket 108: the app model asks for the ship state of the worktrees, applies the answer, and holds
/// the notices, the sign-in pane, and the text that waits for a pane.
@MainActor
@Suite struct ShipModelTests {
    let plotB = "plotaaaaab"
    let plotC = "plotaaaaac"

    /// A model with plots B and C, B active, and a refresher that waits on `sleep`. An archived plot is
    /// in the archived list only.
    func rig(_ fake: FakeLoam, archived: [String] = []) -> (model: AppModel, sleep: ManualSleep) {
        let sleep = ManualSleep()
        let model = AppModel(client: fake.client(), shipRefresh: ShipRefresher(sleep: { try await sleep.sleep($0) }))
        model.shell = "/bin/zsh"
        model.apply([plotB, plotC].filter { !archived.contains($0) }.map(plot), archived: archived.map(plot))
        model.activate(plot: plotB)
        return (model, sleep)
    }

    /// Starts the refresher and waits for the refreshes of the start: the active plot, then the other.
    func started(_ fake: FakeLoam, archived: [String] = []) async -> (model: AppModel, sleep: ManualSleep) {
        let (model, sleep) = rig(fake, archived: archived)
        model.shipRefresh.start()
        await waitForRefreshes(fake, archived.isEmpty ? 2 : 1)
        return (model, sleep)
    }

    func send(_ model: AppModel, to pane: PaneID, event name: String = "Stop") {
        let id = model.workspace.session(of: pane)!.sessionID!
        model.apply(paneEvent(name, id), to: pane)
    }

    /// A session pane in the active plot that started and works.
    func sessionPane(_ model: AppModel) -> PaneID {
        model.openTab(.session)
        let pane = model.workspace.focusedPane!
        model.apply(paneEvent("SessionStart", model.workspace.spec(of: pane)!.sessionID!), to: pane)
        send(model, to: pane, event: "UserPromptSubmit")
        return pane
    }

    // MARK: The answer of a refresh

    @Test func aRefreshAppliesTheRowsOfThePlot() async throws {
        let fake = try FakeLoam([("worktree_list_stages", 0)])
        let model = AppModel(client: fake.client())
        await model.refreshWorktrees(plot: plotB)
        #expect(fake.args() == ["worktree list plotaaaaab --refresh --json"])
        #expect(model.worktrees[plotB]?.count == 16)
        #expect(model.worktrees[plotB]?.first?.stage == .merged)
    }

    @Test func aFailedRefreshKeepsTheRowsAndSetsNoError() async throws {
        let fake = try FakeLoam([("worktree_list", 0), ("error_generic", 1)])
        let model = AppModel(client: fake.client())
        await model.reloadWorktrees()
        let before = model.worktrees
        #expect(!before.isEmpty)
        await model.refreshWorktrees(plot: plotB)
        #expect(model.worktrees == before)
        #expect(model.lastError == nil)
    }

    @Test func aRefreshWithNoWorktreesClearsThePlot() async throws {
        let fake = try FakeLoam([("worktree_list", 0), ("worktree_list_empty", 0)])
        let model = AppModel(client: fake.client())
        await model.reloadWorktrees()
        #expect(model.worktrees[plotB] != nil)
        await model.refreshWorktrees(plot: plotB)
        #expect(model.worktrees[plotB] == nil)
    }

    @Test func aRefreshLeavesTheOtherPlotsAlone() async throws {
        let fake = try FakeLoam([("worktree_list", 0), ("worktree_list_empty", 0)])
        let model = AppModel(client: fake.client())
        await model.reloadWorktrees()
        let before = model.worktrees[plotB]
        await model.refreshWorktrees(plot: plotC)
        #expect(model.worktrees[plotB] == before)
        #expect(fake.args().last == "worktree list plotaaaaac --refresh --json")
    }

    /// A fake `loam` for the race between a refresh and a read of the cache. The refresh answers with
    /// the stage rows. The plain reads answer with the older rows of `worktree_list`, as the cache is
    /// when a worktree is new. The first plain read, or the refresh, waits for a `go` file.
    private func fakeWithHeldCall(holding: String, laterReadsAnswerWith later: String) throws -> (fake: FakeLoam, go: URL) {
        let fake = try FakeLoam([("", 0)])
        let go = fake.dir.appendingPathComponent("go")
        func path(_ name: String) -> String { Fixtures.dir.appendingPathComponent("\(name).json").path }
        let count = fake.dir.appendingPathComponent("plain-count").path
        let wait = "while [ ! -f '\(go.path)' ]; do sleep 0.01; done"
        try """
        echo "$@" >> '\(fake.argsLog.path)'
        case "$*" in
        *--refresh*) \(holding == "refresh" ? wait : ":"); cat '\(path("worktree_list_stages"))';;
        *) n=$(cat '\(count)' 2>/dev/null || echo 0); echo $((n+1)) > '\(count)'
           if [ "$n" = 0 ]; then \(holding == "plain" ? wait : ":"); cat '\(path("worktree_list"))'
           else cat '\(path(later))'; fi;;
        esac
        """.write(to: fake.script, atomically: true, encoding: .utf8)
        return (fake, go)
    }

    @Test func aPlainReadThatStartedBeforeARefreshDoesNotReplaceIt() async throws {
        // The first plain read waits. It would put the older rows back after the refresh.
        let (fake, go) = try fakeWithHeldCall(holding: "plain", laterReadsAnswerWith: "worktree_list_stages")
        let model = AppModel(client: fake.client())
        let plain = Task { await model.reloadWorktrees() }
        await waitUntil("the read starts") { !fake.args().isEmpty }
        await model.refreshWorktrees(plot: plotB)
        FileManager.default.createFile(atPath: go.path, contents: Data())
        await plain.value
        #expect(model.worktrees[plotB]?.count == 16)
    }

    @Test func aPlainReadThatAppliedDuringARefreshIsReadAgainAfterIt() async throws {
        // The read in the middle of the refresh lists one worktree. The cache lists that worktree
        // after the refresh too, so the last read decides.
        let (fake, go) = try fakeWithHeldCall(holding: "refresh", laterReadsAnswerWith: "worktree_list")
        let model = AppModel(client: fake.client())
        let refresh = Task { await model.refreshWorktrees(plot: plotB) }
        await waitUntil("the refresh starts") { !refreshCalls(fake).isEmpty }
        await model.reloadWorktrees()
        #expect(model.worktrees[plotB]?.count == 1)
        FileManager.default.createFile(atPath: go.path, contents: Data())
        await refresh.value
        #expect(fake.args().filter { $0 == "worktree list --json" }.count == 2)
        #expect(model.worktrees[plotB]?.count == 1)
    }

    // MARK: Triggers

    @Test func openingAPlotRefreshesIt() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        model.activate(plot: plotC)
        await waitForRefreshes(fake, 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaac --refresh --json")
        model.shipRefresh.stop()
    }

    @Test func aPlotThatIsActiveAlreadyAndHomeGetNoRefresh() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        model.activate(plot: plotB)
        model.activateHome()
        await settle()
        #expect(refreshCalls(fake).count == 2)
        // The way back from Home is an open.
        model.activate(plot: plotB)
        await waitForRefreshes(fake, 3)
        model.shipRefresh.stop()
    }

    @Test func startRefreshesTheActivePlotThenTheOtherPlots() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        #expect(refreshCalls(fake) == ["worktree list plotaaaaab --refresh --json", "worktree list plotaaaaac --refresh --json"])
        model.shipRefresh.stop()
    }

    @Test func anArchivedPlotGetsNoRefresh() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake, archived: [plotC])
        await model.shipRefresh.refresh(plotC)
        await settle()
        #expect(refreshCalls(fake) == ["worktree list plotaaaaab --refresh --json"])
        model.shipRefresh.stop()
    }

    @Test func aStopEventStartsOneRefreshAfterTheWindow() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, sleep) = await started(fake)
        let pane = sessionPane(model)
        send(model, to: pane)
        await sleep.waiting(for: model.shipRefresh.timing.stopWindow)
        #expect(refreshCalls(fake).count == 2)
        sleep.release(model.shipRefresh.timing.stopWindow)
        await waitForRefreshes(fake, 3)
        await settle()
        #expect(refreshCalls(fake).count == 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --json")
        model.shipRefresh.stop()
    }

    @Test func theStopEventsOfOnePlotJoinOneRefresh() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, sleep) = await started(fake)
        let panes = [sessionPane(model), sessionPane(model)]
        for pane in panes { send(model, to: pane) }
        await sleep.waiting(for: model.shipRefresh.timing.stopWindow)
        #expect(sleep.count(model.shipRefresh.timing.stopWindow) == 1)
        sleep.release(model.shipRefresh.timing.stopWindow)
        await waitForRefreshes(fake, 3)
        await settle()
        #expect(refreshCalls(fake).count == 3)
        model.shipRefresh.stop()
    }

    @Test func otherEventsAndOtherPanesStartNoWindow() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, sleep) = await started(fake)
        let window = model.shipRefresh.timing.stopWindow
        // A turn starts. A shell has no session. A session of Home belongs to no plot.
        let pane = sessionPane(model)
        model.openTab(.shell)
        model.activateHome()
        let home = sessionPane(model)
        send(model, to: home)
        // The pane of the plot gets a Stop for a session it does not run.
        model.apply(paneEvent("Stop", "another-session"), to: pane)
        await settle()
        #expect(sleep.count(window) == 0)
        model.shipRefresh.stop()
    }

    @Test func aStopInAnArchivedPlotStartsNoWindow() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, sleep) = await started(fake)
        let pane = sessionPane(model)
        model.apply([plot(plotC)], archived: [plot(plotB)])
        send(model, to: pane)
        await settle()
        #expect(sleep.count(model.shipRefresh.timing.stopWindow) == 0)
        model.shipRefresh.stop()
    }

    @Test func theActivePlotRefreshesOnItsTimerOnlyWhileLoamIsFrontmost() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, sleep) = await started(fake)
        let interval = model.shipRefresh.timing.activeInterval
        model.isFrontmost = { false }
        await sleep.waiting(for: interval)
        sleep.release(interval)
        await sleep.waiting(for: interval)
        await settle()
        #expect(refreshCalls(fake).count == 2)
        model.isFrontmost = { true }
        sleep.release(interval)
        await waitForRefreshes(fake, 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --json")
        model.shipRefresh.stop()
    }

    @Test func settingsAskAgainForTheActivePlot() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        await model.checkGitHub()
        #expect(refreshCalls(fake).count == 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --json")
        model.activateHome()
        await model.checkGitHub()
        #expect(refreshCalls(fake).count == 3)
        model.shipRefresh.stop()
    }

    @Test func aLaunchWithoutTheFeedStartsNoRefresh() async throws {
        let fake = try FakeLoam([("version", 0), ("setup_check", 0), ("list", 0), ("list_archived", 0), ("changes", 0), ("worktree_list_empty", 0)])
        let model = AppModel(client: fake.client())
        await model.launch(startFeed: false)
        #expect(!model.shipRefresh.isRunning)
        #expect(refreshCalls(fake).isEmpty)
    }

    @Test func quitStopsTheRefresh() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        #expect(model.shipRefresh.isRunning)
        model.prepareForQuit()
        #expect(!model.shipRefresh.isRunning)
    }

    // MARK: Notices

    @Test func aNoticeShowsForTheNoteOfTheRowsAndDismissHidesIt() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let model = AppModel(client: fake.client())
        #expect(model.shipNotices(for: plotB).isEmpty)
        await model.refreshWorktrees(plot: plotB)
        #expect(model.shipNotices(for: plotB) == [.ghSignedOut])
        model.dismiss(.ghSignedOut)
        #expect(model.shipNotices(for: plotB).isEmpty)
        // The next refresh brings the same note. The dismissed notice stays hidden, in every plot.
        await model.refreshWorktrees(plot: plotB)
        await model.refreshWorktrees(plot: plotC)
        #expect(model.shipNotices(for: plotB).isEmpty)
        #expect(model.shipNotices(for: plotC).isEmpty)
    }

    @Test func aNoticeGoesWhenTheNoteGoes() async throws {
        let fake = try FakeLoam([("worktree_list_stages", 0)])
        let model = AppModel(client: fake.client())
        await model.refreshWorktrees(plot: plotB)
        #expect(model.shipNotices(for: plotB).isEmpty)
    }

    // MARK: Text for a pane

    @Test func textWaitsForThePaneToHaveATerminal() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot(plotB)])
        model.activate(plot: plotB)
        model.openTab(.shell)
        let pane = model.workspace.focusedPane!
        var ready = false
        var typed: [String] = []
        model.typeIntoPane = { _, text in
            guard ready else { return false }
            typed.append(text)
            return true
        }
        try model.type("gh auth login", into: pane)
        model.deliverUnsentText()
        #expect(typed.isEmpty)
        ready = true
        model.deliverUnsentText()
        #expect(typed == ["gh auth login"])
        model.deliverUnsentText()
        #expect(typed == ["gh auth login"])
    }

    @Test func textForAPaneThatClosedIsDropped() throws {
        let model = AppModel(client: LoamClient())
        model.apply([plot(plotB)])
        model.activate(plot: plotB)
        model.openTab(.shell)
        let pane = model.workspace.focusedPane!
        var typed: [String] = []
        model.typeIntoPane = { _, _ in false }
        try model.type("gh auth login", into: pane)
        model.closePane(pane)
        model.typeIntoPane = { _, text in typed.append(text); return true }
        model.deliverUnsentText()
        #expect(typed.isEmpty)
    }

    /// A model with a shell pane in plot B and a terminal that takes text. `typed` holds what it took.
    func shellModel(wait: Duration = .seconds(30)) -> (model: AppModel, pane: PaneID, typed: ShipBox<[String]>) {
        let model = AppModel(client: LoamClient())
        model.apply([plot(plotB)])
        model.activate(plot: plotB)
        model.openTab(.shell)
        model.shellWait = wait
        let typed = ShipBox<[String]>([])
        model.typeIntoPane = { _, text in typed.value.append(text); return true }
        return (model, model.workspace.focusedPane!, typed)
    }

    @Test func textForAShellWaitsForItsFirstTitle() async throws {
        let (model, pane, typed) = shellModel()
        try model.typeAtPrompt("gh auth login", into: pane)
        model.deliverUnsentText()
        await settle()
        #expect(typed.value.isEmpty)
        model.setTerminalTitle("user@host:~", of: pane)
        await waitUntil("the text is typed") { !typed.value.isEmpty }
        #expect(typed.value == ["gh auth login"])
    }

    @Test func textForAShellWaitsNoLongerThanTheLimit() async throws {
        let (model, pane, typed) = shellModel(wait: .milliseconds(50))
        try model.typeAtPrompt("gh auth login", into: pane)
        #expect(typed.value.isEmpty)
        await waitUntil("the text is typed") { !typed.value.isEmpty }
        #expect(typed.value == ["gh auth login"])
    }

    @Test func aShellThatClosesBeforeItsPromptGetsNoText() async throws {
        let (model, pane, typed) = shellModel(wait: .milliseconds(50))
        try model.typeAtPrompt("gh auth login", into: pane)
        model.closePane(pane)
        await settle()
        #expect(typed.value.isEmpty)
    }

    @Test func aShellThatShowedItsPromptGetsTheTextAtOnce() throws {
        let (model, pane, typed) = shellModel()
        model.setTerminalTitle("user@host:~", of: pane)
        try model.typeAtPrompt("gh auth login", into: pane)
        #expect(typed.value == ["gh auth login"])
    }

    /// Loam types text as a paste and presses no Return. A program with no bracketed paste reads a line
    /// break inside the text as Return, so the model refuses such text where the caller can see it.
    @Test func textWithALineBreakInsideIsRefusedAtOnce() {
        let (model, pane, typed) = shellModel()
        #expect(throws: PaneTextError.lineBreakInside) { try model.type("one\ntwo", into: pane) }
        #expect(throws: PaneTextError.lineBreakInside) { try model.typeAtPrompt("one\ntwo", into: pane) }
        model.deliverUnsentText()
        #expect(typed.value.isEmpty)
    }

    @Test func aLineBreakAtTheEndOfTheTextIsDroppedBeforeItWaits() throws {
        let (model, pane, typed) = shellModel()
        try model.type("gh auth login\n", into: pane)
        #expect(typed.value == ["gh auth login"])
    }

    /// A terminal that refuses the text drops it and shows why. The text does not wait for ever.
    @Test func textThatTheTerminalRefusesIsDroppedAndTheErrorShows() throws {
        let (model, pane, _) = shellModel()
        model.typeIntoPane = { _, _ in throw PaneTextError.lineBreakInside }
        try model.type("gh auth login", into: pane)
        #expect(model.lastError == PaneTextError.lineBreakInside.description)
        var typed: [String] = []
        model.typeIntoPane = { _, text in typed.append(text); return true }
        model.deliverUnsentText()
        #expect(typed.isEmpty)
    }

    // MARK: Sign in

    @Test func signInOpensAShellInThePlotWithTheCommandTypedAndNotSent() async {
        let model = AppModel(client: LoamClient())
        model.apply([plot(plotB)])
        model.activate(plot: plotB)
        model.shellWait = .seconds(30)
        var typed: [(PaneID, String)] = []
        model.typeIntoPane = { pane, text in typed.append((pane, text)); return true }
        await model.signInToGitHub()
        let pane = model.workspace.focusedPane!
        #expect(model.workspace.spec(of: pane)?.kind == .shell)
        #expect(model.workspace.spec(of: pane)?.space == .plot(plotB))
        // The command waits for the prompt of the shell.
        #expect(typed.isEmpty)
        model.setTerminalTitle("user@host:~", of: pane)
        await waitUntil("the command is typed") { !typed.isEmpty }
        #expect(typed.count == 1)
        #expect(typed.first?.0 == pane)
        // No line break: the person reads the command and presses Return.
        #expect(typed.first?.1 == "gh auth login")
    }

    @Test func theRefreshComesWhenThePaneOfTheSignInCloses() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let (model, _) = await started(fake)
        model.typeIntoPane = { _, _ in true }
        await model.signInToGitHub()
        let pane = model.workspace.focusedPane!
        model.openTab(.shell)
        let other = model.workspace.focusedPane!
        model.closePane(other)
        await settle()
        #expect(refreshCalls(fake).count == 2)
        model.closePane(pane)
        await waitForRefreshes(fake, 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --json")
        model.shipRefresh.stop()
    }
}
