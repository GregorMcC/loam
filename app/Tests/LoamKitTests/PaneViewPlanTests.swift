import Foundation
import Testing

@testable import LoamKit

/// A pane's new view waits for the safe close of its old view (ticket 61), so two processes never
/// hold one session. Each test plays the window: it closes what `toClose` names, builds what
/// `toBuild` names, and finishes the closes by hand.
@MainActor
@Suite struct PaneViewPlanTests {
    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: id, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/repo/a", at: "2026-10-03T09:00:00Z", source: nil, notificationType: nil)
    }

    /// Two plots. "plotaaaaab" is active with a started session and a shell split.
    func model(_ fake: FakeLoam) -> (model: AppModel, session: PaneID, shell: PaneID) {
        let model = AppModel(client: fake.client())
        model.shell = "/bin/zsh"
        model.apply([plot("plotaaaaab"), plot("plotaaaaac")])
        model.openTab(.session)
        let session = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        let id = model.workspace.spec(of: session)!.sessionID!
        model.apply(event("SessionStart", id), to: session)
        model.apply(event("Stop", id), to: session)
        model.split(.sideBySide, .shell, folder: "/repo/a")
        let shell = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        return (model, session, shell)
    }

    /// One render: starts the closes and builds the views. Returns the finish of each close.
    func render(_ plan: PaneViewPlan, _ workspace: Workspace) -> (closes: [PaneID: () -> Void], built: [PaneID]) {
        var closes: [PaneID: () -> Void] = [:]
        for pane in plan.toClose(in: workspace) { closes[pane] = plan.closeStarted(pane) }
        let built = plan.toBuild(in: workspace)
        for pane in built { plan.didBuild(pane, in: workspace) }
        return (closes, built)
    }

    @Test func aResumeWaitsForTheCloseOfTheOldProcess() throws {
        let (model, session, shell) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        #expect(Set(render(plan, model.workspace).built) == [session, shell])

        model.paneExited(session)
        model.resumeSession(in: session)
        let step = render(plan, model.workspace)
        #expect(Array(step.closes.keys) == [session])
        #expect(step.built.isEmpty, "the resume started while the old process closes")
        #expect(plan.isClosing(session))
        #expect(render(plan, model.workspace).built.isEmpty)

        step.closes[session]?()
        #expect(render(plan, model.workspace).built == [session])
        let command = model.workspace.spec(of: session)?.command ?? ""
        #expect(command.contains("resume"))
    }

    @Test func anUnarchivedPlotWaitsForTheArchiveClose() async throws {
        let fake = try FakeLoam([("archive", 0), ("error_generic", 1), ("unarchive", 0), ("error_generic", 1)])
        let (model, session, shell) = try model(fake)
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)

        #expect(await model.archivePlot("plotaaaaab"))
        let step = render(plan, model.workspace)
        #expect(Set(step.closes.keys) == [session, shell])

        // Unarchive and show the plot at once, while the old panes still close.
        #expect(await model.unarchivePlot("plotaaaaab"))
        model.apply([plot("plotaaaaab"), plot("plotaaaaac")])
        model.activate(plot: "plotaaaaab")
        #expect(Set(model.workspace.livePaneIDs(of: "plotaaaaab")) == [session, shell])
        #expect(render(plan, model.workspace).built.isEmpty, "a pane started while its old process closes")

        // Each pane starts once its own close finishes.
        step.closes[session]?()
        #expect(render(plan, model.workspace).built == [session])
        step.closes[shell]?()
        #expect(render(plan, model.workspace).built == [shell])
    }

    @Test func aPaneWaitsForEveryCloseOfItsOlderViews() throws {
        let (model, session, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)
        model.paneExited(session)
        model.resumeSession(in: session)
        let first = render(plan, model.workspace).closes[session]
        // A second close of the same pane before the first finishes, for example at quit.
        let second = plan.closeStarted(session)
        first?()
        first?()  // A second call counts once.
        #expect(plan.toBuild(in: model.workspace).isEmpty)
        second()
        #expect(plan.toBuild(in: model.workspace) == [session])
    }

    @Test func theLastCloseOfAPaneCallsBackAndTheLastCloseWakesTheWaiters() throws {
        let plan = PaneViewPlan()
        var finished: [PaneID] = []
        plan.onCloseFinished = { finished.append($0) }
        var idle = 0
        plan.whenClosesFinish { idle += 1 }
        #expect(idle == 1, "with no close, the waiter runs at once")

        let (one, two) = (PaneID(), PaneID())
        let a = plan.closeStarted(one)
        let b = plan.closeStarted(two)
        let c = plan.closeStarted(two)
        plan.whenClosesFinish { idle += 1 }
        a()
        #expect(finished == [one] && idle == 1 && plan.isClosingAny)
        b()
        #expect(finished == [one], "pane two still has a close that runs")
        c()
        #expect(finished == [one, two] && idle == 2 && !plan.isClosingAny)
    }

    @Test func aForgottenPaneIsBuiltAgainWithNoClose() throws {
        let (model, session, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)
        plan.forget(session)
        #expect(!plan.isClosing(session))
        #expect(plan.toBuild(in: model.workspace) == [session])
    }
}
