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

/// Waits until `count` refresh calls ran.
@MainActor private func waitForRefreshes(_ fake: FakeLoam, _ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil("\(count) refreshes", sourceLocation: sourceLocation) { refreshCalls(fake).count >= count }
}

/// A value that a closure can change.
@MainActor final class ShipBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Changes what the fake of `fakePrinting` prints from now on.
private func reprint(_ output: Data, from fake: FakeLoam) throws {
    try output.write(to: fake.dir.appendingPathComponent("output.json"))
}

/// True when every one of the plots holds the note of a signed out or missing `gh` on its rows.
@MainActor private func holdNote(_ model: AppModel, _ plots: [String]) -> Bool {
    plots.allSatisfy { plot in
        model.worktrees[plot]?.contains { $0.prNote == .ghSignedOut || $0.prNote == .ghMissing } == true
    }
}

/// Waits long enough for a call that must not come.
private func settle() async { try? await Task.sleep(for: .milliseconds(200)) }

/// Ticket 108: the app model asks for the ship state of the worktrees, applies the answer, and holds
/// the notices, the sign-in pane, and the text that waits for a pane.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ShipModelTests {
    let plotB = "plotaaaaab"
    let plotC = "plotaaaaac"
    let plotD = "plotaaaaad"
    let plotE = "plotaaaaae"

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
        // After the refresh, the merged row reads the setting of its repo (ticket 113).
        await model.mergesSettled()
        #expect(fake.args() == ["worktree list plotaaaaab --refresh --json", "show plotaaaaab --json"])
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
    /// when a worktree is new. The first plain read, or the refresh, waits for a `go` file. A plain read takes its
    /// number before it logs its call, so a read that starts after a test saw the call of the first is never first.
    private func fakeWithHeldCall(holding: String, laterReadsAnswerWith later: String) throws -> (fake: FakeLoam, go: URL) {
        let fake = try FakeLoam([("", 0)])
        let go = fake.dir.appendingPathComponent("go")
        func path(_ name: String) -> String { Fixtures.dir.appendingPathComponent("\(name).json").path }
        let wait = "while [ ! -f '\(go.path)' ]; do sleep 0.01; done"
        try """
        case "$*" in *--refresh*) ;; *) \(FakeScript.takeNumber("plain", in: fake.dir));; esac
        echo "$@" >> '\(fake.argsLog.path)'
        case "$*" in
        *--refresh*) \(holding == "refresh" ? wait : ":"); cat '\(path("worktree_list_stages"))';;
        *) if [ "$n" = 0 ]; then \(holding == "plain" ? wait : ":"); cat '\(path("worktree_list"))'
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

    // MARK: The keys

    /// Each refresh writes a new `pr_checked_at`, so it changes the rows, and the window renders. The
    /// render must not move the keys to the terminal: you can type in a field of the plot panel then.
    @Test func aRefreshThatChangesTheRowsLeavesTheKeysWhereTheyAre() async throws {
        let fake = try fakePrinting(Data("[]".utf8))
        let model = AppModel(client: fake.client())
        model.shell = "/bin/zsh"
        model.apply([plot(plotB)])
        model.activate(plot: plotB)
        model.openTab(.shell)

        // The window: it builds the views and asks the plan about the keys at every render.
        let plan = PaneViewPlan()
        let terminal = NSObject()  // The view that would take the keys.
        var renders = 0
        var moves = 0
        func render() {
            renders += 1
            for pane in plan.toBuild(in: model.workspace) { plan.didBuild(pane, in: model.workspace) }
            if plan.movesKeys(in: model.workspace, target: terminal) { moves += 1 }
        }
        model.onWorkspaceChange = render
        render()
        #expect(moves == 1, "the first render gives the keys to the pane")

        func rows(checkedAt: String) throws -> Data {
            var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
            for index in rows.indices where rows[index]["pr_checked_at"] != nil { rows[index]["pr_checked_at"] = checkedAt }
            return try JSONSerialization.data(withJSONObject: rows)
        }
        for minute in ["00:01", "00:02", "00:03"] {
            try reprint(rows(checkedAt: "2026-01-01T12:\(minute):00Z"), from: fake)
            let before = model.worktrees[plotB]
            let rendersBefore = renders
            await model.refreshWorktrees(plot: plotB)
            #expect(model.worktrees[plotB] != before, "the refresh changed the rows")
            #expect(renders > rendersBefore, "the window rendered for the new rows")
        }
        #expect(moves == 1, "a refresh moved the keys")
    }

    // MARK: A fix of gh

    /// The Ready to merge row hides while any plot holds `gh_missing` or `gh_signed_out`. "Check again" asks
    /// for one plot only, so a refresh that comes back with no such note refreshes the other plots that
    /// still hold one, and the row comes back.
    @Test func aRefreshWithNoGitHubNoteRefreshesTheOtherPlotsThatHoldOne() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let (model, _) = await started(fake)
        await waitUntil("both plots hold the note") { holdNote(model, [plotB, plotC]) }
        #expect(!model.sidebar.showsReadyToMerge)
        await settle()
        #expect(refreshCalls(fake).count == 2, "a refresh that comes back with the note asks for no other plot")

        try reprint(Fixtures.data("worktree_list_stages"), from: fake)
        await model.checkGitHub()  // Plot B, the active plot.
        await waitForRefreshes(fake, 4)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaac --refresh --json")
        await waitUntil("plot C has no note") { model.worktrees[plotC]?.allSatisfy { $0.prNote != .ghSignedOut } == true }
        #expect(model.shipNotices(for: plotC).isEmpty)
        #expect(model.sidebar.showsReadyToMerge)
        await settle()
        #expect(refreshCalls(fake).count == 4)
        model.shipRefresh.stop()
    }

    /// The plots that the first answer sent do not send each other: three plots make three refreshes after the
    /// answer of the first, not more.
    @Test func theRefreshesThatAFixStartsStartNoMoreOfThem() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_missing"))
        let sleep = ManualSleep()
        let model = AppModel(client: fake.client(), shipRefresh: ShipRefresher(sleep: { try await sleep.sleep($0) }))
        model.apply([plotB, plotC, "plotaaaaad"].map(plot))
        model.activate(plot: plotB)
        model.shipRefresh.start()
        await waitForRefreshes(fake, 3)
        await waitUntil("the three plots hold the note") { holdNote(model, [plotB, plotC, "plotaaaaad"]) }
        await settle()
        #expect(refreshCalls(fake).count == 3)
        try reprint(Fixtures.data("worktree_list_stages"), from: fake)
        await model.checkGitHub()
        await waitForRefreshes(fake, 6)
        await waitUntil("no plot holds a note") { model.worktrees.values.joined().allSatisfy { $0.prNote != .ghMissing } }
        await settle()
        #expect(refreshCalls(fake).count == 6, "\(refreshCalls(fake).count) refreshes, not 6")
        model.shipRefresh.stop()
    }

    /// A model with the plots B, C, D and E, B active, whose refreshes go through `probe`. The probe records each
    /// refresh when it starts, and holds it while `probe.holds` is true. The timers never fire, and the test
    /// starts the refresher.
    func probedModel(_ fake: FakeLoam, _ probe: RefreshProbe) -> AppModel {
        let sleep = ManualSleep()
        let model = AppModel(client: fake.client(), shipRefresh: ShipRefresher(sleep: { try await sleep.sleep($0) }))
        model.apply([plotB, plotC, plotD, plotE].map(plot))
        model.activate(plot: plotB)
        model.shipRefresh.run = { [weak model] id in
            await probe.run(id)
            await model?.refreshWorktrees(plot: id)
        }
        return model
    }

    /// The rechecks of a fix run one after the other. Fourteen plots with a note must not start fourteen
    /// `loam worktree list --refresh` together, so each recheck waits until the one before it ends.
    @Test func theRechecksOfAFixRunOneAfterTheOther() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let probe = RefreshProbe()
        let model = probedModel(fake, probe)
        let everyPlot = [plotB, plotC, plotD, plotE]
        model.shipRefresh.start()
        await waitUntil("every plot holds the note") { holdNote(model, everyPlot) }
        try reprint(Fixtures.data("worktree_list_stages"), from: fake)
        let before = probe.started.count

        probe.holds = true
        let check = Task { await model.checkGitHub() }  // Plot B, the active plot.
        await waitUntil("the refresh of plot B") { probe.started.count == before + 1 }
        probe.finishOne()
        await check.value
        for (index, plot) in [plotC, plotD, plotE].enumerated() {
            await waitUntil("the recheck of \(plot)") { probe.started.count == before + 2 + index }
            await settle()
            #expect(probe.started.count == before + 2 + index, "a recheck started while the one before it ran")
            probe.finishOne()
        }
        await waitUntil("no plot holds the note") { !everyPlot.contains { holdNote(model, [$0]) } }
        await settle()
        #expect(Array(probe.started.dropFirst(before)) == everyPlot, "each plot refreshes once, in the order of the sidebar")
        model.shipRefresh.stop()
    }

    /// A plot whose refresh runs when the fix comes gets no second refresh. The refresher would run one more
    /// after the one that runs, since a trigger during a refresh makes one more.
    @Test func aPlotThatRefreshesAlreadyGetsNoSecondRefreshAtAFix() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let probe = RefreshProbe()
        let model = probedModel(fake, probe)
        model.shipRefresh.start()
        await waitUntil("every plot holds the note") { holdNote(model, [plotB, plotC, plotD, plotE]) }
        try reprint(Fixtures.data("worktree_list_stages"), from: fake)
        let before = probe.started.count

        probe.holds = true
        let running = Task { await model.shipRefresh.refresh(plotC) }  // The refresh of plot C runs when the fix comes.
        await waitUntil("the refresh of plot C") { probe.started.count == before + 1 }
        probe.holds = false
        await model.checkGitHub()  // Plot B comes back clean, and the plots that hold the note recheck.
        await waitUntil("the rechecks of plots D and E") { probe.started.count == before + 4 }
        await settle()
        probe.finishOne()  // The refresh of plot C ends.
        await running.value
        await settle()
        #expect(Array(probe.started.dropFirst(before)) == [plotC, plotB, plotD, plotE], "plot C refreshed again")
        model.shipRefresh.stop()
    }

    /// An answer that proves nothing about `gh` starts no refresh of another plot: a plot with no worktrees, and
    /// a plot whose repo is not on GitHub, which `gh` never asked about.
    @Test func anAnswerThatSaysNothingAboutGitHubRefreshesNoOtherPlot() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let (model, _) = await started(fake)
        await waitUntil("both plots hold the note") { holdNote(model, [plotB, plotC]) }
        for answer in [Data("[]".utf8), try stageRows(note: "no_github_remote")] {
            try reprint(answer, from: fake)
            let before = refreshCalls(fake).count
            await model.refreshWorktrees(plot: plotB)
            await settle()
            #expect(refreshCalls(fake).count == before + 1)
            #expect(model.shipNotices(for: plotC) == [.ghSignedOut])
        }
        model.shipRefresh.stop()
    }

    /// Ticket 109: a refresh of one worktree asks GitHub about that worktree only. The other rows of the answer are
    /// what the core cached, so they prove nothing about `gh` now.
    @Test func aRefreshOfOneWorktreeJudgesGitHubByThatWorktreeOnly() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let (model, _) = await started(fake)
        await waitUntil("both plots hold the note") { holdNote(model, [plotB, plotC]) }
        // The asked worktree has a note that is no sign of a fix. The cached rows have none.
        var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["worktree"].flatMap { ($0 as? [String: Any])?["id"] as? String } == "wtreaaaaah" })
        rows[index]["pr_note"] = "no_access"
        try reprint(JSONSerialization.data(withJSONObject: rows), from: fake)
        let before = refreshCalls(fake).count
        #expect(await model.refreshWorktree("wtreaaaaah"))
        await settle()
        #expect(refreshCalls(fake).count == before + 1, "a cached row started a refresh of another plot")
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --worktree wtreaaaaah --json")
        #expect(model.shipNotices(for: plotC) == [.ghSignedOut])
        model.shipRefresh.stop()
    }

    @Test func aRefreshOfAnUnknownWorktreeAsksNoOne() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let (model, _) = await started(fake)
        let before = refreshCalls(fake).count
        #expect(await !model.refreshWorktree("nope"))
        await settle()
        #expect(refreshCalls(fake).count == before)
        model.shipRefresh.stop()
    }

    @Test func anArchivedPlotThatHoldsANoteGetsNoRefreshAtAFix() async throws {
        let fake = try fakePrinting(try stageRows(note: "gh_signed_out"))
        let (model, _) = await started(fake, archived: [plotC])
        await waitUntil("plot B holds the note") { holdNote(model, [plotB]) }
        await model.refreshWorktrees(plot: plotC)
        #expect(holdNote(model, [plotC]))
        #expect(refreshCalls(fake).count == 2)
        try reprint(Fixtures.data("worktree_list_stages"), from: fake)
        await model.checkGitHub()
        await settle()
        #expect(refreshCalls(fake).count == 3)
        #expect(refreshCalls(fake).last == "worktree list plotaaaaab --refresh --json")
        model.shipRefresh.stop()
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
