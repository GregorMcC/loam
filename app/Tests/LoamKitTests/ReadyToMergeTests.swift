import Foundation
import Testing

@testable import LoamKit

/// Ticket 107: the Ready to merge row of the sidebar, the stage mark on a worktree row, and ⌘⇧L.
/// The worktrees come from the `worktree_list_stages` fixture (made-up example/widgets data), moved
/// into the plots of each test.
@MainActor
@Suite struct ReadyToMergeTests {
    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: "Plot \(id)", what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    /// A worktree of `plot` at `stage`, from the fixture. `repo` is the repo it belongs to.
    func worktree(_ id: String, _ plot: String, _ stage: WorktreeStage, note: PRNote = .noNote,
                  repo: String? = nil) throws -> WorktreeStatus {
        let all = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
        var status = try #require(all.first { $0.stage == stage })
        status.worktree.id = id
        status.worktree.plotID = plot
        status.worktree.name = id
        status.worktree.branch = id
        status.worktree.repo = repo ?? "/tmp/\(plot)/repo"
        status.prNote = note
        return status
    }

    func mainRepo(_ plot: String, extra: [String] = []) -> [String: [RepoCheckout]] {
        [plot: [RepoCheckout(id: "r-\(plot)", path: "/tmp/\(plot)/repo", isMain: true, branch: "main")]
            + extra.map { RepoCheckout(id: "r-\($0)", path: "/tmp/\(plot)/\($0)", isMain: false, branch: "main") }]
    }

    func sidebar(_ plots: [String], _ worktrees: [String: [WorktreeStatus]], workspace: Workspace = Workspace(),
                 selected: String? = nil, repos: [String: [RepoCheckout]] = [:]) -> SidebarModel {
        SidebarModel(plots: plots.map(plot), workspace: workspace, collapsed: false, worktrees: worktrees,
                     repos: repos, selectedWorktree: selected)
    }

    /// A worktree of a run that has not ended lands at the desk, which lands the run too. The row leaves it out, so
    /// a merge from the sidebar cannot remove the worktree under the run.
    @Test func aWorktreeOfARunIsNotInTheRow() throws {
        let worktrees = ["a": [try worktree("a1", "a", .readyToMerge), try worktree("a2", "a", .readyToMerge)]]
        let model = SidebarModel(plots: [plot("a")], workspace: Workspace(), collapsed: false, worktrees: worktrees,
                                 runWorktrees: ["a2"])
        #expect(model.readyToMerge.map(\.id) == ["a1"])
    }

    // MARK: The count

    @Test func countsTheReadyWorktreesOfEveryPlot() throws {
        let model = sidebar(["a", "b"], [
            "a": [try worktree("a1", "a", .readyToMerge), try worktree("a2", "a", .checksFailed)],
            "b": [try worktree("b1", "b", .readyToMerge)],
        ])
        #expect(model.readyToMergeCount == 2)
        #expect(model.readyToMerge.map(\.id) == ["a1", "b1"])
        #expect(model.showsReadyToMerge)
    }

    @Test func anArchivedPlotDoesNotCount() throws {
        // The core lists the worktrees of an archived plot too. The sidebar lists only the other plots.
        let model = sidebar(["a"], [
            "a": [try worktree("a1", "a", .checksFailed)],
            "old": [try worktree("o1", "old", .readyToMerge)],
        ])
        #expect(model.readyToMergeCount == 0)
        #expect(model.readyToMerge.isEmpty)
    }

    @Test func aWorktreeThatIsNotReadyDoesNotCount() throws {
        let stages: [WorktreeStage] = [.merged, .closed, .inMergeQueue, .conflicts, .changesRequested, .checksFailed,
                                       .approvalNeeded, .draft, .behindBase, .checksRunning, .waitingForReview, .blocked,
                                       .pushedNoPR, .notPushed]
        let all = try stages.map { try worktree("w-\($0.rawValue)", "a", $0) }
        let model = sidebar(["a"], ["a": all])
        #expect(model.readyToMergeCount == 0)
    }

    @Test func aReadyWorktreeWithAGoneFolderDoesNotCount() throws {
        var gone = try worktree("a1", "a", .readyToMerge)
        gone.missing = true
        #expect(sidebar(["a"], ["a": [gone]]).readyToMergeCount == 0)
    }

    // MARK: When the row shows

    @Test func theRowShowsWhileAnyWorktreeHasAPR() throws {
        let none = sidebar(["a"], ["a": [try worktree("a1", "a", .checksFailed)]])
        #expect(none.showsReadyToMerge && none.readyToMergeCount == 0)
    }

    @Test func theRowHidesWhenNoWorktreeHasAPR() throws {
        #expect(!sidebar(["a"], [:]).showsReadyToMerge)
        let local = [try worktree("a1", "a", .notPushed), try worktree("a2", "a", .pushedNoPR)]
        let model = sidebar(["a"], ["a": local])
        #expect(!model.showsReadyToMerge && model.readyToMergeCount == 0)
    }

    @Test func theRowHidesWhenGhIsMissingOrSignedOut() throws {
        for note in [PRNote.ghMissing, .ghSignedOut] {
            let ready = try worktree("a1", "a", .readyToMerge, note: note)
            let model = sidebar(["a"], ["a": [ready]])
            #expect(!model.showsReadyToMerge, "\(note)")
            // The last answer is old. The row does not send you to a worktree that it cannot vouch for.
            #expect(model.readyToMerge.isEmpty, "\(note)")
        }
    }

    @Test func oneWorktreeThatSaysGhIsMissingHidesTheRow() throws {
        let model = sidebar(["a", "b"], [
            "a": [try worktree("a1", "a", .readyToMerge)],
            "b": [try worktree("b1", "b", .checksFailed, note: .ghMissing)],
        ])
        #expect(!model.showsReadyToMerge)
    }

    @Test func otherNotesDoNotHideTheRow() throws {
        for note in [PRNote.noNote, .offline, .rateLimited, .noAccess, .noGitHubRemote] {
            let model = sidebar(["a"], ["a": [try worktree("a1", "a", .readyToMerge, note: note)]])
            #expect(model.showsReadyToMerge && model.readyToMergeCount == 1, "\(note)")
        }
    }

    @Test func aNoteOfAnArchivedPlotDoesNotHideTheRow() throws {
        let model = sidebar(["a"], [
            "a": [try worktree("a1", "a", .readyToMerge)],
            "old": [try worktree("o1", "old", .checksFailed, note: .ghSignedOut)],
        ])
        #expect(model.showsReadyToMerge)
    }

    // MARK: The order

    /// Plots with panes come first in the sidebar, then plots with none. Each plot lists the main
    /// checkout's worktrees, then the other repos', each oldest first.
    @Test func theOrderIsTheOrderOfTheSidebar() throws {
        var ws = Workspace()
        ws.openTab(PaneSpec(kind: .shell, space: .plot("c"), title: "shell"))
        let model = sidebar(["a", "b", "c"], [
            "a": [try worktree("a1", "a", .readyToMerge)],
            "b": [try worktree("b-web", "b", .readyToMerge, repo: "/tmp/b/web"),
                  try worktree("b1", "b", .readyToMerge), try worktree("b2", "b", .readyToMerge)],
            "c": [try worktree("c1", "c", .readyToMerge), try worktree("c2", "c", .checksFailed)],
        ], workspace: ws, repos: mainRepo("b", extra: ["web"]))
        #expect(model.withPanes.map(\.id) == ["c"])
        #expect(model.readyToMerge.map(\.id) == ["c1", "a1", "b1", "b2", "b-web"])
        #expect(model.orderedWorktrees.map(\.id) == ["c1", "c2", "a1", "b1", "b2", "b-web"])
    }

    @Test func theCycleMovesToTheNextAndWraps() {
        let order = ["a1", "b1", "b2", "c1"]
        let ready: Set = ["a1", "b2", "c1"]
        #expect(AttentionCycle.next(order: order, matching: ready, after: "a1") == "b2")
        #expect(AttentionCycle.next(order: order, matching: ready, after: "b2") == "c1")
        #expect(AttentionCycle.next(order: order, matching: ready, after: "c1") == "a1")
        // The current one is not ready: the next one after it.
        #expect(AttentionCycle.next(order: order, matching: ready, after: "b1") == "b2")
        // No current one, or one that the order does not hold: the first.
        #expect(AttentionCycle.next(order: order, matching: ready, after: nil) == "a1")
        #expect(AttentionCycle.next(order: order, matching: ready, after: "zz") == "a1")
        #expect(AttentionCycle.next(order: order, matching: [], after: "a1") == nil)
        #expect(AttentionCycle.next(order: order, matching: ["a1"], after: "a1") == "a1")
    }

    // MARK: The mark on the row

    @Test func aWorktreeRowCarriesItsMark() throws {
        let ready = try worktree("a1", "a", .readyToMerge)
        let local = try worktree("a2", "a", .notPushed)
        let model = sidebar(["a"], ["a": [ready, local]], repos: mainRepo("a"))
        let rows = model.tree(of: "a").checkouts[0].worktrees.compactMap(\.worktree)
        #expect(rows[0].mark?.label == "#22" && rows[0].mark?.stage == .readyToMerge)
        #expect(rows[1].mark?.stage == .notPushed && rows[1].mark?.label == nil)
    }

    /// The row of a closed repo opens when ⌘⇧L selects a worktree under it.
    @Test func aWorktreeKnowsTheRepoRowThatListsIt() throws {
        let list = ["a": [try worktree("a1", "a", .readyToMerge), try worktree("a-web", "a", .readyToMerge, repo: "/tmp/a/web")]]
        let model = sidebar(["a"], list, repos: mainRepo("a", extra: ["web"]))
        #expect(model.repoRow(holding: "a1")?.id == "main-a")
        #expect(model.repoRow(holding: "a-web")?.id == "repo-r-web")
        #expect(model.repoRow(holding: "nope") == nil)
        // With no repo row, the worktree sits right under its plot.
        #expect(sidebar(["a"], list).repoRow(holding: "a1") == nil)
    }

    // MARK: ⌘⇧L

    /// A model with plots a and b. Their worktrees are `a-fail` and `a-ready` in a, and `b-ready` in b.
    /// `a-fail` is never ready. The names say what the fixture gives the others, and `notReady` turns a
    /// ready one into a failed one. `note` goes on every worktree.
    func appModel(notReady: Set<String> = [], note: PRNote = .noNote) async throws -> AppModel {
        func stage(_ id: String) -> WorktreeStage { id.hasSuffix("-ready") && !notReady.contains(id) ? .readyToMerge : .checksFailed }
        let list = try [("a-fail", "a"), ("a-ready", "a"), ("b-ready", "b")].map {
            try worktree($0.0, $0.1, stage($0.0), note: note)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("list.json")
        try JSONEncoder().encode(list).write(to: json)
        // `loam worktree list --json` prints the file, whatever the arguments are.
        try FakeScript.install("#!/bin/sh\ncat '\(json.path)'\n", at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([plot("a"), plot("b")])
        await model.reloadWorktrees()
        return model
    }

    func ref(_ id: String, in model: AppModel) throws -> WorktreeRef {
        WorktreeRef(try #require(model.worktreeStatus(id)).worktree)
    }

    @Test func theKeyGoesToTheNextReadyWorktreeAndCycles() async throws {
        let model = try await appModel()
        #expect(model.workspace.activePlotID == "a")
        #expect(model.sidebar.readyToMergeCount == 2)

        #expect(model.goToNextReadyWorktree())
        #expect(model.workspace.activePlotID == "a")
        #expect(model.sidebar.selection == .worktree("a-ready"))

        #expect(model.goToNextReadyWorktree())
        #expect(model.workspace.activePlotID == "b")
        #expect(model.sidebar.selection == .worktree("b-ready"))

        #expect(model.goToNextReadyWorktree())
        #expect(model.workspace.activePlotID == "a")
        #expect(model.sidebar.selection == .worktree("a-ready"))
    }

    /// A plot with a pane comes first in the sidebar, so b-ready is the first ready worktree here.
    @Test func theKeyFocusesTheFirstPaneOfTheWorktree() async throws {
        let model = try await appModel()
        let b = try ref("b-ready", in: model)
        model.activate(plot: "b")
        model.openTab(.shell, worktree: b)
        let first = try #require(model.workspace.focusedPane)
        model.openTab(.shell, worktree: b)
        let second = try #require(model.workspace.focusedPane)
        #expect(first != second)
        model.activate(plot: "a")

        #expect(model.goToNextReadyWorktree())
        #expect(model.workspace.activePlotID == "b")
        #expect(model.workspace.focusedPane == first)
        #expect(model.sidebar.selection == .pane(first))
        #expect(model.selectedWorktree == nil)

        // The pane keeps the place in the cycle: the next one is a-ready, and then b-ready again.
        #expect(model.goToNextReadyWorktree())
        #expect(model.sidebar.selection == .worktree("a-ready"))
        #expect(model.goToNextReadyWorktree())
        #expect(model.workspace.focusedPane == first)
    }

    @Test func aPaneInAWorktreeThatIsNotReadyStartsTheCycleAfterIt() async throws {
        let model = try await appModel()
        model.openTab(.shell, worktree: try ref("a-fail", in: model))
        // a-fail sits right before a-ready in the sidebar.
        #expect(model.goToNextReadyWorktree())
        #expect(model.sidebar.selection == .worktree("a-ready"))
    }

    @Test func movingTheFocusClearsTheSelectedWorktree() async throws {
        let model = try await appModel()
        #expect(model.goToNextReadyWorktree())
        #expect(model.selectedWorktree == "a-ready")

        model.openTab(.shell)  // A new pane takes the focus.
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.selectedWorktree == nil)
        #expect(model.sidebar.selection == .pane(pane))

        #expect(model.goToNextReadyWorktree())
        #expect(model.selectedWorktree == "a-ready")
        model.activate(plot: "b")
        #expect(model.selectedWorktree == nil)
        #expect(model.sidebar.selection == .plot("b"))
    }

    /// Plot a is active and the pane has the focus. ⌘⇧L selects a-ready, which has no pane, so the focus
    /// stays on the pane while the sidebar selects the worktree row.
    func modelWithAWorktreeSelectedOverAFocusedPane() async throws -> (model: AppModel, pane: PaneID) {
        let model = try await appModel()
        model.openTab(.shell)
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.goToNextReadyWorktree())
        #expect(model.selectedWorktree == "a-ready" && model.workspace.focusedPane == pane)
        #expect(model.sidebar.selection == .worktree("a-ready"))
        return (model, pane)
    }

    /// The selection of the worktree has ended, so the sidebar selects where you are, and the next ⌘⇧L
    /// starts from there. It selects a-ready again. From the old selection it would select b-ready.
    func expectTheSelectionEnded(_ model: AppModel, _ pane: PaneID) {
        #expect(model.selectedWorktree == nil)
        #expect(model.sidebar.selection == .pane(pane))
        #expect(model.goToNextReadyWorktree())
        #expect(model.sidebar.selection == .worktree("a-ready"))
    }

    /// A click on the row of the focused pane: the focus and the active plot stay as they are.
    @Test func aClickOnTheRowOfTheFocusedPaneEndsTheSelectedWorktree() async throws {
        let (model, pane) = try await modelWithAWorktreeSelectedOverAFocusedPane()
        model.goToPane(pane)
        expectTheSelectionEnded(model, pane)
    }

    /// A click into the terminal of the focused pane.
    @Test func aClickIntoTheFocusedTerminalEndsTheSelectedWorktree() async throws {
        let (model, pane) = try await modelWithAWorktreeSelectedOverAFocusedPane()
        model.focus(pane)
        expectTheSelectionEnded(model, pane)
    }

    /// A key that steps to another pane, in a tab with a single pane. The focus stays where it is.
    @Test func aStepOfThePaneFocusEndsTheSelectedWorktree() async throws {
        let (model, pane) = try await modelWithAWorktreeSelectedOverAFocusedPane()
        model.focusPane(.next)
        #expect(model.workspace.focusedPane == pane)
        expectTheSelectionEnded(model, pane)
    }

    /// A click on the row of the active plot.
    @Test func aClickOnTheActivePlotEndsTheSelectedWorktree() async throws {
        let (model, pane) = try await modelWithAWorktreeSelectedOverAFocusedPane()
        model.activate(plot: "a")
        expectTheSelectionEnded(model, pane)
    }

    /// The selected worktree is a row of the active plot. A worktree of another plot, or one that the
    /// list does not hold, selects nothing.
    @Test func aSelectedWorktreeCountsOnlyInTheActivePlot() throws {
        var ws = Workspace()
        ws.activate("a")
        let list = ["a": [try worktree("a1", "a", .readyToMerge)], "b": [try worktree("b1", "b", .readyToMerge)]]
        #expect(sidebar(["a", "b"], list, workspace: ws, selected: "a1").selection == .worktree("a1"))
        #expect(sidebar(["a", "b"], list, workspace: ws, selected: "b1").selection == .plot("a"))
        #expect(sidebar(["a", "b"], list, workspace: ws, selected: "nope").selection == .plot("a"))
    }

    @Test func theKeyDoesNothingWhenNoWorktreeIsReady() async throws {
        let model = try await appModel(notReady: ["a-ready", "b-ready"])
        model.openTab(.shell)
        let before = model.workspace
        #expect(model.sidebar.showsReadyToMerge && model.sidebar.readyToMergeCount == 0)
        #expect(!model.goToNextReadyWorktree())
        #expect(model.selectedWorktree == nil && model.workspace == before)
    }

    @Test func theKeyDoesNothingWhileTheRowIsHidden() async throws {
        for note in [PRNote.ghMissing, .ghSignedOut] {
            let model = try await appModel(note: note)
            #expect(!model.goToNextReadyWorktree(), "\(note)")
            #expect(model.selectedWorktree == nil && model.workspace.activePlotID == "a", "\(note)")
        }
    }

    @Test func theKeyDoesNothingWithNoPlots() {
        let model = AppModel(client: LoamClient(binary: URL(fileURLWithPath: "/opt/loam/bin/loam"), environment: [:]))
        #expect(!model.goToNextReadyWorktree())
        #expect(model.nextReadyWorktree() == nil)
    }

    // MARK: The key

    @Test func commandShiftLRoutesToTheReadyWorktree() {
        let chord = KeyChord([.command, .shift], "l")
        #expect(LoamKeys.route(chord, isGhosttyBinding: false) == .loam(.nextReadyWorktree))
        #expect(LoamKeys.route(chord, isGhosttyBinding: true) == .loam(.nextReadyWorktree))
        #expect(LoamKeys.chord(for: .nextReadyWorktree) == chord)
        #expect(LoamKeys.fixedKey(for: chord)?.title == "Next Worktree Ready to Merge")
        // ⌘L keeps its own command.
        #expect(LoamKeys.route(KeyChord(.command, "l"), isGhosttyBinding: false) == .loam(.nextPaneThatNeedsYou))
    }

    /// Ghostty has no default key for ⌘⇧L (`ghostty +list-keybinds --default`, 1.3.1 and the pinned commit).
    @Test func noGhosttyMenuActionUsesTheKey() {
        let defaults = LoamKeys.ghosttyMenuActions.map(\.defaultChord)
        #expect(!defaults.contains(KeyChord([.command, .shift], "l")))
    }

    @Test func aKeybindOfTheKeyIsAClash() {
        let text = """
        keybind = cmd+shift+l=new_tab
        keybind = super+shift+l>x=new_split:right
        keybind = cmd+l=new_tab
        keybind = cmd+shift+l=unbind
        """
        let clashes = GhosttyConfigFiles.clashes(in: GhosttyConfigFiles.entries(in: text, file: "/c"))
        #expect(clashes.map(\.key.command) == [.nextReadyWorktree, .nextReadyWorktree, .nextPaneThatNeedsYou])
        #expect(clashes[0].description == "Ghostty config /c line 1: keybind = cmd+shift+l=new_tab uses ⇧⌘L. "
            + "Loam uses ⇧⌘L for Next Worktree Ready to Merge, so Loam's key wins.")
    }
}
