import Foundation
import Testing

@testable import LoamKit

/// Seeded and shell panes in the workspace and the app model (ticket 28).
@MainActor
@Suite struct PaneModelTests {
    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func model(_ fake: FakeLoam? = nil, environment: [String: String] = ["LOAM_HOME": "/tmp/loam-home"]) throws -> AppModel {
        let binary = fake?.binary ?? URL(fileURLWithPath: "/opt/loam/bin/loam")
        let model = AppModel(client: LoamClient(binary: binary, environment: environment))
        model.shell = "/bin/zsh"
        model.apply([plot("plotaaaaab", "Loam")])
        return model
    }

    @Test func newTabWithASessionRunsLoamStartWithANewID() throws {
        let model = try model()
        model.openTab(.session)
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        let spec = try #require(model.workspace.spec(of: pane))
        let id = try #require(spec.sessionID)
        #expect(spec.kind == .session)
        #expect(spec.command == "/bin/zsh -lc 'exec /opt/loam/bin/loam start plotaaaaab --session-id \(id)'")
        #expect(spec.env == ["LOAM_HOME": "/tmp/loam-home"])
        #expect(UUID(uuidString: id) != nil && id == id.lowercased())
        #expect(model.workspace.session(of: pane)?.sessionID == id)
        #expect(model.workspace.state(of: pane) == .running)
    }

    @Test func eachSeededPaneGetsItsOwnID() throws {
        let model = try model()
        model.openTab(.session)
        model.split(.sideBySide, .session)
        let ids = model.workspace.paneIDs(of: "plotaaaaab").compactMap { model.workspace.spec(of: $0)?.sessionID }
        #expect(ids.count == 2 && ids[0] != ids[1])
    }

    @Test func aShellTabStartsInTheMainRepo() async throws {
        let fake = try FakeLoam([("show_full", 0)])
        let model = try model(fake)
        await model.openShellTab()
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        let spec = try #require(model.workspace.spec(of: pane))
        #expect(spec.kind == .shell && spec.command == nil)
        #expect(spec.folder == "/tmp/loam-contract/repos/docs")
        #expect(fake.args() == ["show plotaaaaab --json"])
    }

    @Test func aShellTabOfAPlotWithNoReposStartsInThePlotFolder() async throws {
        let fake = try FakeLoam([("show", 0)])
        let model = try model(fake)
        await model.splitShell(.stacked)  // No tab yet: nothing.
        #expect(model.workspace.paneCount(of: "plotaaaaab") == 0)
        await model.openShellTab()
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        #expect(model.workspace.spec(of: pane)?.folder == "/tmp/loam-home/plots/plotaaaaab")
        await model.splitShell(.stacked)
        #expect(model.workspace.paneCount(of: "plotaaaaab") == 2)
    }

    @Test func aFailedShowGivesThePlotFolder() async throws {
        let fake = try FakeLoam([("error_generic", 1)])
        let model = try model(fake)
        #expect(await model.startFolder(of: "plotaaaaab") == "/tmp/loam-home/plots/plotaaaaab")
    }

    @Test func socketEventsMoveTheSeededPaneAndShellPanesIgnoreThem() throws {
        let model = try model()
        model.openTab(.session)
        let seeded = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        let id = try #require(model.workspace.spec(of: seeded)?.sessionID)
        model.openTab(.shell)
        let shell = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)

        model.apply(paneEvent("SessionStart", id, source: "startup"), to: seeded)
        model.apply(paneEvent("UserPromptSubmit", id), to: seeded)
        #expect(model.workspace.state(of: seeded) == .working)
        model.apply(paneEvent("SessionStart", "x", source: "startup"), to: shell)
        #expect(model.workspace.state(of: shell) == .running)
        #expect(model.workspace.session(of: shell)?.sessionID == nil)
    }

    @Test func theReviewFindsThePaneOfASessionAlsoAfterClear() throws {
        let model = try model()
        model.openTab(.session)
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        let id = try #require(model.workspace.spec(of: pane)?.sessionID)
        model.apply(paneEvent("SessionStart", id, source: "startup"), to: pane)
        model.apply(paneEvent("SessionStart", "cleared", source: "clear"), to: pane)
        #expect(model.review.paneLookup?("cleared") == PaneRef(id: pane, name: "claude \u{00B7} Loam"))
        #expect(model.review.paneLookup?(id)?.id == pane)
        #expect(model.review.paneLookup?("nobody") == nil)

        model.openTab(.shell)
        model.review.onGoToPane?(PaneRef(id: pane, name: ""))
        #expect(model.workspace.selectedTab(of: "plotaaaaab")?.focused == pane)
    }

    @Test func resumeReplacesAnEndedPaneInPlace() throws {
        let model = try model()
        model.openTab(.session)
        model.split(.sideBySide, .shell)
        let tree = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.tree)
        let pane = tree.paneIDs[0]
        let id = try #require(model.workspace.spec(of: pane)?.sessionID)
        model.focus(pane)

        model.resumeSession(in: pane)  // Still runs: nothing.
        #expect(model.workspace.spec(of: pane) != nil)

        model.apply(paneEvent("SessionStart", id, source: "startup"), to: pane)
        model.apply(paneEvent("SessionStart", "after-clear", source: "clear"), to: pane)
        model.paneExited(pane)
        #expect(model.workspace.state(of: pane) == .ended)
        model.resumeSession(in: pane)

        // The same pane, in the same place, with a new launch.
        let tab = try #require(model.workspace.selectedTab(of: "plotaaaaab"))
        #expect(tab.tree == tree && tab.focused == pane)
        #expect(model.workspace.launch(of: pane) == 1)
        let spec = try #require(model.workspace.spec(of: pane))
        #expect(spec.command == "/bin/zsh -lc 'exec /opt/loam/bin/loam resume after-clear'")
        #expect(spec.sessionID == "after-clear" && spec.kind == .session)
        let session = try #require(model.workspace.session(of: pane))
        #expect(session.state == .running && !session.exited && !session.started)
        #expect(session.pastSessionIDs == [id])  // The review still finds the pane for the first ID.
        #expect(model.workspace.pane(forSession: id) == pane)
    }

    @Test func aPaneWhoseSessionNeverStartedCannotResume() throws {
        let model = try model()
        model.openTab(.session)
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        model.paneExited(pane)
        model.resumeSession(in: pane)
        #expect(model.workspace.spec(of: pane) != nil)
    }

    @Test func newSessionStartsAFreshIDInTheSameRepo() throws {
        let model = try model()
        model.openTab(.session, repo: "web")
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        let spec = try #require(model.workspace.spec(of: pane))
        #expect(spec.command?.contains("start plotaaaaab --repo web --session-id") == true)
        model.newSession(in: pane)  // Still runs: nothing.
        #expect(model.workspace.spec(of: pane) != nil)
        model.paneExited(pane)
        model.newSession(in: pane)
        let freshSpec = try #require(model.workspace.spec(of: pane))
        #expect(model.workspace.launch(of: pane) == 1)
        #expect(freshSpec.repo == "web" && freshSpec.sessionID != spec.sessionID)
        #expect(freshSpec.command?.contains("start plotaaaaab --repo web --session-id") == true)
    }

    @Test func aShellPaneHasNoEndedState() throws {
        let model = try model()
        model.openTab(.shell)
        let pane = try #require(model.workspace.selectedTab(of: "plotaaaaab")?.focused)
        model.newSession(in: pane)
        model.resumeSession(in: pane)
        #expect(model.workspace.spec(of: pane)?.kind == .shell)
    }

    @Test func theWorkspaceKeepsSessionsThroughAnEncode() throws {
        var ws = Workspace()
        let pane = ws.openTab(PaneSpec(kind: .session, plot: "A", sessionID: "a"))
        ws.apply(paneEvent("SessionStart", "a", source: "startup"), to: pane)
        ws.apply(paneEvent("SessionStart", "b", source: "clear"), to: pane)
        let copy = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(copy == ws)
        #expect(copy.session(of: pane)?.sessionID == "b")
        #expect(copy.pane(forSession: "a") == pane)
    }
}
