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

    // MARK: The keys (ticket 108)

    /// The views that can take the keys: the terminal of a pane, and its Session ended bar. The window asks
    /// for the keys with the view that would take them, as `PaneContainerView.focusTarget` says.
    let terminalView = NSObject()
    let endedBarView = NSObject()

    /// The window renders for every change of the model, such as a refresh of the ship state. It moves the
    /// first responder to the focused pane only when the focus moved, the pane got a new view, or the view
    /// that takes the keys changed, so a render never takes the keys from a field that you type in, such as
    /// one in the plot panel.
    @Test func theKeysMoveOnlyWhenTheFocusOrTheViewChanges() throws {
        let (model, session, shell) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView), "no pane has a view yet")
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "the first render gives the keys to the focused pane")
        #expect(model.workspace.focusedPane == shell)
        for _ in 0..<3 {
            _ = render(plan, model.workspace)
            #expect(!plan.movesKeys(in: model.workspace, target: terminalView), "a render with the focus where it was")
        }

        model.focus(session)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "another pane has the focus")
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView))

        model.openTab(.shell)
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "a new tab")
        model.selectTab(index: 0)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "another tab")
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView))

        model.activate(plot: "plotaaaaac")
        model.openTab(.shell)
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "another plot")
        model.activateHome()
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView), "Home has no pane")
        model.activate(plot: "plotaaaaac")
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "the plot that you left for Home, where the keys have no pane")
        model.activate(plot: "plotaaaaab")
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "back in the first plot")
    }

    /// The Session ended bar takes the keys from the terminal of the focused pane when its session ends, with
    /// the focus where it was: the target view changed.
    @Test func theViewThatTakesTheKeysCanChangeWithTheFocusWhereItWas() throws {
        let (model, _, shell) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)
        #expect(model.workspace.focusedPane == shell)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView))
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView))
        #expect(plan.movesKeys(in: model.workspace, target: endedBarView), "the ended bar takes the keys")
        #expect(!plan.movesKeys(in: model.workspace, target: endedBarView))
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "the terminal takes them back at a resume")
    }

    /// The Session ended bar takes the keys when the session ends, but only from the terminal of the pane, or
    /// from nowhere (the window itself holds them). A field that you type in, such as Where it stands in the
    /// plot panel, keeps them: the bar would read "n" as New session and Return as Resume.
    @Test func theEndedBarTakesTheKeysOnlyFromTheTerminalOrFromNowhere() throws {
        let (model, _, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        let field = NSObject()  // A field of the plot panel.

        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView))
        #expect(!plan.movesKeys(in: model.workspace, target: endedBarView, heldBy: field), "the session ended while you type in a field")
        #expect(!plan.movesKeys(in: model.workspace, target: endedBarView, heldBy: field))

        // The same for a session that ends while the terminal holds the keys, and while nothing holds them.
        for holder in [terminalView, nil] {
            let plan = PaneViewPlan()
            _ = render(plan, model.workspace)
            #expect(plan.movesKeys(in: model.workspace, target: terminalView))
            #expect(plan.movesKeys(in: model.workspace, target: endedBarView, heldBy: holder), "the keys were with \(holder == nil ? "nothing" : "the terminal")")
            #expect(!plan.movesKeys(in: model.workspace, target: endedBarView, heldBy: endedBarView))
        }
    }

    /// The field keeps the keys only when the target changes alone. Any other reason still moves them to the
    /// pane, also from a field.
    @Test func aFieldKeepsTheKeysOnlyWhenTheTargetChangesAlone() throws {
        let (model, session, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        let field = NSObject()
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "the first render")

        model.focus(session)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "another pane has the focus")
        model.openTab(.shell)
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "a new tab")
        model.selectTab(index: 0)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "another tab")
        model.activate(plot: "plotaaaaac")
        model.openTab(.shell)
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "another plot")
        model.activate(plot: "plotaaaaab")
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "back in the first plot")

        // A resume gives the focused pane a new view, which takes the keys from a field.
        #expect(model.workspace.focusedPane == session)
        model.paneExited(session)
        model.resumeSession(in: session)
        let step = render(plan, model.workspace)
        step.closes[session]?()
        #expect(render(plan, model.workspace).built == [session])
        #expect(plan.movesKeys(in: model.workspace, target: terminalView, heldBy: field), "a new view of the pane")
    }

    /// A pane with no view to take the keys leaves them nowhere, so the next view takes them.
    @Test func aFocusedPaneWithNoTargetLeavesTheKeysNowhere() throws {
        let (model, _, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView))
        #expect(!plan.movesKeys(in: model.workspace, target: nil))
        #expect(plan.movesKeys(in: model.workspace, target: terminalView))
    }

    /// A resume gives the pane a new view under the same ID. The keys move to it once it is built, and not
    /// while the old view closes, since the pane has no view then.
    @Test func aNewViewOfTheFocusedPaneTakesTheKeys() throws {
        let (model, session, _) = try model(FakeLoam([]))
        let plan = PaneViewPlan()
        _ = render(plan, model.workspace)
        model.focus(session)
        #expect(plan.movesKeys(in: model.workspace, target: terminalView))

        model.paneExited(session)
        model.resumeSession(in: session)
        let step = render(plan, model.workspace)
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView), "the pane has no view while the old process closes")
        step.closes[session]?()
        #expect(render(plan, model.workspace).built == [session])
        #expect(plan.movesKeys(in: model.workspace, target: terminalView), "the new view takes the keys")
        #expect(!plan.movesKeys(in: model.workspace, target: terminalView))
    }
}
