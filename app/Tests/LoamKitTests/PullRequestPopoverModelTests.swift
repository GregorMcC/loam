import Foundation
import Testing

@testable import LoamKit

/// Ticket 109: the app model opens the PR popover, refreshes the one worktree, runs Re-run failed and
/// Update branch through `loam`, and tells the action bar and the pane header about the PR.
/// The worktrees come from the `worktree_list_stages` fixture (made-up example/widgets data), all in the
/// plot `plotaaaaab`.
@MainActor
@Suite struct PullRequestPopoverModelTests {
    let plotID = "plotaaaaab"
    let nativePanel = "wtreaaaaah"  // Checks failed, #16.

    /// A fake `loam` that logs its arguments and prints a fixture by command. A file named `fail-rerun` or
    /// `fail-update` in its folder makes that command fail as `gh_unavailable`. A file named `hold` makes
    /// every command wait until the file is gone. A file named `hold-2` does the same for the second
    /// command that refreshes. A file named `fail-list` makes the list fail. The list leaves a file
    /// `done-N` when the N-th refresh has printed its answer.
    struct Rig {
        let dir: URL
        let model: AppModel

        var argsLog: URL { dir.appendingPathComponent("args.log") }

        func args() -> [String] {
            ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func refreshes() -> [String] { args().filter { $0.contains("--refresh") } }

        func touch(_ name: String) throws { try Data().write(to: dir.appendingPathComponent(name)) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
    }

    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: "Plot \(id)", what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func rig(loaded: Bool = true) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("popover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["worktree_list_stages", "worktree_rerun", "worktree_update", "error_gh_unavailable"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(dir.path)/args.log'
            n=$(grep -c -e '--refresh' '\(dir.path)/args.log')
            while [ -f '\(dir.path)/hold' ] || [ -f "\(dir.path)/hold-$n" ]; do sleep 0.01; done
            fail() { cat '\(dir.path)/error_gh_unavailable.json'; exit 17; }
            case "$1 $2" in
              "worktree rerun") [ -f '\(dir.path)/fail-rerun' ] && fail; cat '\(dir.path)/worktree_rerun.json';;
              "worktree update") [ -f '\(dir.path)/fail-update' ] && fail; cat '\(dir.path)/worktree_update.json';;
              *) [ -f '\(dir.path)/fail-list' ] && fail; cat '\(dir.path)/worktree_list_stages.json'; touch "\(dir.path)/done-$n";;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([plot(plotID)])
        if loaded { await model.reloadWorktrees() }
        return Rig(dir: dir, model: model)
    }

    /// Waits until `condition` holds. Fails the test after 5 s.
    func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "\(what) did not happen")
    }

    func idle(_ model: AppModel) async {
        await waitUntil("the refresh ended") { !model.prPopover.isRefreshing }
    }

    // MARK: Open and close

    @Test func openingShowsTheWorktreeAndRefreshesOnlyIt() async throws {
        let rig = try await rig()
        let model = rig.model
        #expect(!model.prPopover.isOpen)
        #expect(model.openPullRequest(nativePanel))
        #expect(model.prPopover.isOpen && model.prPopover.worktreeID == nativePanel)
        await waitUntil("the refresh ran") { !rig.refreshes().isEmpty }
        await idle(model)
        #expect(rig.refreshes() == ["worktree list plotaaaaab --refresh --worktree \(nativePanel) --json"])
        #expect(model.prPopover.answeredAt != nil)
        #expect(model.worktrees[plotID]?.count == 16)
    }

    @Test func theRefreshShowsWhileItRuns() async throws {
        let rig = try await rig()
        try rig.touch("hold")
        #expect(rig.model.openPullRequest(nativePanel))
        #expect(rig.model.prPopover.isRefreshing)
        #expect(rig.model.prPopover.answeredAt == nil)
        rig.remove("hold")
        await idle(rig.model)
        #expect(rig.model.prPopover.answeredAt != nil)
    }

    @Test func anUnknownWorktreeOpensNothing() async throws {
        let rig = try await rig()
        let before = rig.args()
        #expect(!rig.model.openPullRequest("nope"))
        #expect(!rig.model.prPopover.isOpen)
        #expect(rig.args() == before)
    }

    @Test func closingClearsTheStateOfTheOpen() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        model.closePullRequest()
        #expect(!model.prPopover.isOpen && model.prPopover.worktreeID == nil)
        #expect(model.prPopover.answeredAt == nil && model.prPopover.note == nil && model.prPopover.running == nil)
        model.closePullRequest()  // A second close does nothing.
        #expect(!model.prPopover.isOpen)
    }

    @Test func aSecondOpenReplacesTheFirst() async throws {
        let rig = try await rig()
        let model = rig.model
        let opens = model.prPopover.openCount
        model.openPullRequest(nativePanel, anchor: .windowRect(CGRect(x: 1, y: 2, width: 3, height: 4)))
        model.openPullRequest("wtreaaaaag")
        #expect(model.prPopover.worktreeID == "wtreaaaaag")
        #expect(model.prPopover.anchor == .actionBar)
        #expect(model.prPopover.openCount == opens + 2)
        await idle(model)
    }

    @Test func theChangesOfOpenAndCloseReachTheWindow() async throws {
        let rig = try await rig()
        var changes: [Bool] = []
        rig.model.prPopover.onOpenChange = { changes.append($0) }
        rig.model.openPullRequest(nativePanel)
        rig.model.closePullRequest()
        rig.model.closePullRequest()
        #expect(changes == [true, false])
        await idle(rig.model)
    }

    @Test func aFailedRefreshKeepsTheRowsAndTheOpenPopover() async throws {
        let rig = try await rig()
        let before = rig.model.worktrees
        try rig.touch("fail-list")
        rig.model.openPullRequest(nativePanel)
        await idle(rig.model)
        #expect(rig.model.prPopover.isOpen)
        #expect(rig.model.worktrees == before)
        #expect(rig.model.prPopover.answeredAt == nil)
        #expect(rig.model.lastError == nil)
    }

    @Test func theAnswerOfAnOldRefreshDoesNotShowInANewOpen() async throws {
        let rig = try await rig()
        let model = rig.model
        let before = rig.refreshes().count
        try rig.touch("hold-\(before + 1)")
        try rig.touch("hold-\(before + 2)")
        model.openPullRequest(nativePanel)
        await waitUntil("the first refresh started") { rig.refreshes().count == before + 1 }
        model.closePullRequest()
        model.openPullRequest("wtreaaaaag")
        await waitUntil("the second refresh started") { rig.refreshes().count == before + 2 }
        // The first answer comes while the second refresh waits. It is not the answer of this open.
        rig.remove("hold-\(before + 1)")
        await waitUntil("the first answer came") { rig.exists("done-\(before + 1)") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.prPopover.isRefreshing && model.prPopover.answeredAt == nil)
        rig.remove("hold-\(before + 2)")
        await idle(model)
        #expect(model.prPopover.worktreeID == "wtreaaaaag" && model.prPopover.answeredAt != nil)
    }

    @Test func theWorktreeThatLeavesTheListClosesThePopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        // The core no longer lists the worktree (a land removed it).
        try Data("[]".utf8).write(to: rig.dir.appendingPathComponent("worktree_list_stages.json"))
        await model.reloadWorktrees()
        #expect(!model.prPopover.isOpen)
    }

    // MARK: Ready to merge and ⌘⇧L

    @Test func theNextReadyWorktreeOpensItsPopover() async throws {
        let rig = try await rig()
        let model = rig.model
        #expect(model.goToNextReadyWorktree())
        let ready = try #require(model.sidebar.readyToMerge.first?.id)
        #expect(model.selectedWorktree == ready || model.workspace.focusedPane != nil)
        #expect(model.prPopover.worktreeID == ready)
        #expect(model.prPopover.anchor == .actionBar)
        await idle(model)
    }

    @Test func noReadyWorktreeOpensNothing() async throws {
        let rig = try await rig()
        try Data(String(decoding: Fixtures.data("worktree_list_stages"), as: UTF8.self)
            .replacingOccurrences(of: "\"ready_to_merge\"", with: "\"checks_failed\"").utf8)
            .write(to: rig.dir.appendingPathComponent("worktree_list_stages.json"))
        await rig.model.reloadWorktrees()
        #expect(!rig.model.goToNextReadyWorktree())
        #expect(!rig.model.prPopover.isOpen)
    }

    // MARK: Re-run failed and Update branch

    @Test func reRunningTheFailedChecksRunsTheCoreCommandAndAsksAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        await model.rerunFailedChecks()
        #expect(rig.args().contains("worktree rerun plotaaaaab \(nativePanel) --json --actor app"))
        // The popover asks about the worktree again, so the checks show as running.
        #expect(rig.refreshes().count == 2)
        #expect(model.prPopover.running == nil)
        #expect(model.prPopover.note ==
            "GitHub runs the failed checks of 1 run again. Could not re-run the run 302: failed to rerun: HTTP 403: Unable to retry this workflow run because it was created over a month ago (https://api.github.com/repos/example/widgets/actions/runs/302/rerun-failed-jobs)")
        #expect(model.lastError == nil)
    }

    @Test func aRerunThatTheCoreRefusesShowsItsMessageInThePopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("fail-rerun")
        await model.rerunFailedChecks()
        #expect(model.prPopover.note == "the origin of /tmp/loam-contract/repos/web is not on GitHub")
        #expect(model.prPopover.running == nil && model.lastError == nil)
        #expect(rig.refreshes().count == 1)
    }

    @Test func updatingTheBranchRunsTheCoreCommandAndAsksAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest("wtreaaaaak")  // Behind base, #18.
        await idle(model)
        await model.updateBranch()
        #expect(rig.args().contains("worktree update plotaaaaab wtreaaaaak --json --actor app"))
        #expect(model.prPopover.note == "GitHub brought the PR up to date with main.")
        #expect(rig.refreshes().count == 2)
    }

    @Test func anActionNeedsAnOpenPopover() async throws {
        let rig = try await rig()
        let before = rig.args()
        await rig.model.rerunFailedChecks()
        await rig.model.updateBranch()
        #expect(rig.args() == before)
    }

    @Test func aSecondActionWaitsForTheFirst() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold")
        let first = Task { await model.rerunFailedChecks() }
        await waitUntil("the action runs") { model.prPopover.running == .rerunFailed }
        await model.updateBranch()
        #expect(!rig.args().contains { $0.hasPrefix("worktree update") })
        rig.remove("hold")
        await first.value
    }

    @Test func aNoteGoesWhenThePopoverOpensAgain() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        await model.rerunFailedChecks()
        #expect(model.prPopover.note != nil)
        model.closePullRequest()
        model.openPullRequest(nativePanel)
        #expect(model.prPopover.note == nil)
        await idle(model)
    }

    @Test func aLineFromTheViewShowsAsTheNoteOfAnOpenPopoverOnly() async throws {
        let rig = try await rig()
        let model = rig.model
        model.prPopover.say("Copied the branch name.")
        #expect(model.prPopover.note == nil)  // No popover is open.
        model.openPullRequest(nativePanel)
        await idle(model)
        model.prPopover.say("Copied the branch name.")
        #expect(model.prPopover.note == "Copied the branch name.")
        model.openPullRequest(nativePanel)
        #expect(model.prPopover.note == nil)
        await idle(model)
    }

    // MARK: The chip and the pane header

    func workspaceRef(_ id: String, in model: AppModel) throws -> WorktreeRef {
        WorktreeRef(try #require(model.worktreeStatus(id)).worktree)
    }

    @Test func thePaneOfAWorktreeWithAPRHasAChipMark() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        let pane = try #require(model.workspace.focusedPane)
        let mark = try #require(model.pullRequestMark(of: pane))
        #expect(mark.label == "#16" && mark.stage == .checksFailed && mark.symbol == "xmark.circle")
        #expect(mark.stage.words == "Checks failed" && mark.tone == .rust)
    }

    @Test func aPaneInTheMainCheckoutHasNoChip() async throws {
        let rig = try await rig()
        rig.model.openTab(.shell)
        #expect(rig.model.pullRequestMark(of: try #require(rig.model.workspace.focusedPane)) == nil)
    }

    @Test func aPaneInHomeHasNoChip() async throws {
        let rig = try await rig()
        rig.model.activateHome()
        rig.model.openTab(.shell)
        #expect(rig.model.pullRequestMark(of: try #require(rig.model.workspace.focusedPane)) == nil)
    }

    /// The ✎ mark of unpushed work is a mark of the sidebar. The chip is the PR.
    @Test func aWorktreeWithNoPRHasNoChipEvenWithWorkToLose() async throws {
        let rig = try await rig()
        let model = rig.model
        let local = try #require(model.worktrees[plotID]?.first { $0.stage == .notPushed })
        #expect(StageMark(local) != nil)
        model.openTab(.shell, worktree: WorktreeRef(local.worktree))
        #expect(model.pullRequestMark(of: try #require(model.workspace.focusedPane)) == nil)
    }

    @Test func aWorktreeWhoseFolderIsGoneHasNoChip() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        let list = String(decoding: try Fixtures.data("worktree_list_stages"), as: UTF8.self)
            .replacingOccurrences(of: "\"missing\": false", with: "\"missing\": true")
        try Data(list.utf8).write(to: rig.dir.appendingPathComponent("worktree_list_stages.json"))
        await model.reloadWorktrees()
        #expect(model.worktreeStatus(nativePanel)?.missing == true)
        #expect(model.pullRequestMark(of: try #require(model.workspace.focusedPane)) == nil)
    }

    @Test func theChipFollowsTheStateOfTheWorktree() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        let pane = try #require(model.workspace.focusedPane)
        #expect(model.pullRequestMark(of: pane)?.stage == .checksFailed)
        let list = String(decoding: try Fixtures.data("worktree_list_stages"), as: UTF8.self)
            .replacingOccurrences(of: "\"stage\": \"checks_failed\"", with: "\"stage\": \"ready_to_merge\"")
        try Data(list.utf8).write(to: rig.dir.appendingPathComponent("worktree_list_stages.json"))
        await model.reloadWorktrees()
        #expect(model.pullRequestMark(of: pane)?.stage == .readyToMerge)
    }

    @Test func thePaneHeaderShowsTheBranchAndThenThePRNumber() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        #expect(model.branchLabel(of: try #require(model.workspace.focusedPane)) == "native-panel #16")
        let local = try #require(model.worktrees[plotID]?.first { $0.stage == .notPushed })
        model.openTab(.shell, worktree: WorktreeRef(local.worktree))
        #expect(model.branchLabel(of: try #require(model.workspace.focusedPane)) == "local-work")
        model.openTab(.shell)
        #expect(model.branchLabel(of: try #require(model.workspace.focusedPane)) == nil)
    }

    // MARK: The switcher

    @Test func aWorktreeIsFoundByItsPRNumberAndGoesToItsPopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.switcher.open()
        model.switcher.query = "#16"
        let first = try #require(model.switcher.results.first?.item)
        #expect(first.kind == .worktree && first.target == .worktree(nativePanel))
        model.switcher.chooseSelected()
        #expect(!model.switcher.isOpen)
        #expect(model.prPopover.worktreeID == nativePanel && model.prPopover.anchor == .actionBar)
        await idle(model)
    }

    @Test func returnOnAWorktreeWithNoPaneSelectsItsRowAndOpensThePopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.switcher.open()
        model.switcher.query = "native-panel"
        let item = try #require(model.switcher.results.first { $0.item.kind == .worktree }?.item)
        model.switcher.choose(item)
        #expect(model.workspace.activePlotID == plotID)
        #expect(model.selectedWorktree == nativePanel)
        #expect(model.prPopover.worktreeID == nativePanel)
        await idle(model)
    }

    @Test func returnOnAWorktreeWithAPaneFocusesThePane() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        let pane = try #require(model.workspace.focusedPane)
        model.openTab(.shell)
        model.switcher.open()
        model.switcher.query = "#16"
        model.switcher.chooseSelected()
        #expect(model.workspace.focusedPane == pane && model.selectedWorktree == nil)
        #expect(model.prPopover.worktreeID == nativePanel)
        await idle(model)
    }
}
