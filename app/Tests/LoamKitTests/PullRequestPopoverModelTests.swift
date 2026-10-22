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
    /// `fail-update` in its folder makes that command fail as `gh_unavailable` (exit 17), or as `not_ready`
    /// when the file says 16. A file named `hold` makes every command wait until the file is gone. A file
    /// named `hold-2` does the same for the commands that start once the second refresh has started, and
    /// `hold-rerun` and `hold-update` for that command only. A file named `fail-list` makes the list fail.
    /// The list leaves a file `done-N` when the N-th refresh has printed its answer.
    struct Rig {
        let dir: URL
        let model: AppModel

        var argsLog: URL { dir.appendingPathComponent("args.log") }

        func args() -> [String] {
            ((try? String(contentsOf: argsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func refreshes() -> [String] { args().filter { $0.contains("--refresh") } }

        /// The calls of `worktree rerun` or `worktree update`.
        func calls(of command: String) -> Int { args().filter { $0.hasPrefix("worktree \(command) ") }.count }

        func touch(_ name: String, _ text: String = "") throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
    }

    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: "Plot \(id)", what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func rig(loaded: Bool = true) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("popover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["worktree_list_stages", "worktree_rerun", "worktree_update", "error_gh_unavailable", "error_not_ready"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(dir.path)/args.log'
            n=$(grep -c -e '--refresh' '\(dir.path)/args.log')
            while [ -f '\(dir.path)/hold' ] || [ -f "\(dir.path)/hold-$n" ]; do sleep 0.01; done
            fail() {
              [ "$(cat "$1")" = 16 ] && { cat '\(dir.path)/error_not_ready.json'; exit 16; }
              cat '\(dir.path)/error_gh_unavailable.json'; exit 17
            }
            case "$1 $2" in
              "worktree rerun")
                while [ -f '\(dir.path)/hold-rerun' ]; do sleep 0.01; done
                [ -f '\(dir.path)/fail-rerun' ] && fail '\(dir.path)/fail-rerun'; cat '\(dir.path)/worktree_rerun.json';;
              "worktree update")
                while [ -f '\(dir.path)/hold-update' ]; do sleep 0.01; done
                [ -f '\(dir.path)/fail-update' ] && fail '\(dir.path)/fail-update'; cat '\(dir.path)/worktree_update.json';;
              *) [ -f '\(dir.path)/fail-list' ] && fail '\(dir.path)/fail-list'; cat '\(dir.path)/worktree_list_stages.json'
                 touch "\(dir.path)/done-$n";;
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
        #expect(model.prPopover.attemptedAt != nil)
        #expect(model.worktrees[plotID]?.count == 16)
    }

    @Test func theRefreshShowsWhileItRuns() async throws {
        let rig = try await rig()
        try rig.touch("hold")
        #expect(rig.model.openPullRequest(nativePanel))
        #expect(rig.model.prPopover.isRefreshing)
        #expect(rig.model.prPopover.attemptedAt == nil)
        rig.remove("hold")
        await idle(rig.model)
        #expect(rig.model.prPopover.attemptedAt != nil)
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
        #expect(model.prPopover.attemptedAt == nil && model.prPopover.note == nil && model.prPopover.running == nil)
        model.closePullRequest()  // A second close does nothing.
        #expect(!model.prPopover.isOpen)
    }

    /// A control of the window, which says where it is now.
    final class Control: PopoverAnchorControl {
        var windowRect: CGRect? = CGRect(x: 1, y: 2, width: 3, height: 4)
    }

    @Test func aSecondOpenReplacesTheFirst() async throws {
        let rig = try await rig()
        let model = rig.model
        let opens = model.prPopover.openCount
        let control = Control()
        model.openPullRequest(nativePanel, anchor: .control(control))
        #expect(model.prPopover.anchor == .control(control) && model.prPopover.anchor != .control(Control()))
        model.openPullRequest("wtreaaaaag")
        #expect(model.prPopover.worktreeID == "wtreaaaaag")
        #expect(model.prPopover.anchor == .actionBar)
        #expect(model.prPopover.openCount == opens + 2)
        await idle(model)
    }

    /// The window shows and hides the popover on a change, and places it at its control on each open, also
    /// on one that moves an open popover to another worktree.
    @Test func theChangesOfOpenAndCloseReachTheWindow() async throws {
        let rig = try await rig()
        var changes: [Bool] = []
        var places: [String?] = []
        rig.model.prPopover.onOpenChange = { changes.append($0) }
        rig.model.prPopover.onOpen = { places.append(rig.model.prPopover.worktreeID) }
        rig.model.openPullRequest(nativePanel)
        rig.model.openPullRequest("wtreaaaaag")
        rig.model.closePullRequest()
        rig.model.closePullRequest()
        #expect(changes == [true, false])
        #expect(places == [nativePanel, "wtreaaaaag"])
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
        #expect(rig.model.prPopover.attemptedAt == nil)
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
        #expect(model.prPopover.isRefreshing && model.prPopover.attemptedAt == nil)
        rig.remove("hold-\(before + 2)")
        await idle(model)
        #expect(model.prPopover.worktreeID == "wtreaaaaag" && model.prPopover.attemptedAt != nil)
    }

    /// Holding ⌘⇧L or a click on the chip of an open popover opens it again and again. Each open joins the
    /// refresh that runs, so one `loam` process asks GitHub.
    @Test func twoOpensInARowRunOneRefresh() async throws {
        let rig = try await rig()
        let model = rig.model
        try rig.touch("hold")
        model.openPullRequest(nativePanel)
        model.openPullRequest(nativePanel)
        await waitUntil("the refresh started") { rig.refreshes().count == 1 }
        model.closePullRequest()
        model.openPullRequest(nativePanel)
        #expect(model.prPopover.isRefreshing)
        try await Task.sleep(for: .milliseconds(200))
        rig.remove("hold")
        await idle(model)
        #expect(rig.refreshes().count == 1)
        #expect(model.prPopover.attemptedAt != nil)
    }

    /// Refresh in the ⌘J menu is an explicit ask: a push made a moment ago is not in a refresh that started
    /// before it, so the menu asks again after the one that runs. An open of the popover joins it instead.
    @Test func aRefreshFromTheMenuAsksAgainAfterTheRefreshThatRuns() async throws {
        let rig = try await rig()
        let model = rig.model
        try rig.touch("hold")
        model.openPullRequest(nativePanel)
        await waitUntil("the refresh started") { rig.refreshes().count == 1 }
        let menu = Task { await model.refreshWorktree(nativePanel, afterChange: true) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.refreshes().count == 1)
        rig.remove("hold")
        #expect(await menu.value)
        await idle(model)
        #expect(rig.refreshes().count == 2)
    }

    /// Refresh in the ⌘J menu, with the popover of the worktree open: the popover says "Updating…".
    @Test func aRefreshFromTheMenuShowsInTheOpenPopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold")
        let menu = Task { await model.refreshWorktree(nativePanel, afterChange: true) }
        await waitUntil("the popover shows the refresh") { model.prPopover.isRefreshing }
        rig.remove("hold")
        #expect(await menu.value)
        #expect(!model.prPopover.isRefreshing && model.prPopover.attemptedAt != nil)
        #expect(rig.refreshes().count == 2)
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

    @Test func aButtonThatEndsAfterThePopoverClosedStillRefreshesTheWorktree() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold-rerun")
        let rerun = Task { await model.rerunFailedChecks() }
        await waitUntil("the re-run runs") { model.prPopover.running == .rerunFailed && rig.calls(of: "rerun") == 1 }
        model.closePullRequest()
        rig.remove("hold-rerun")
        await rerun.value
        #expect(rig.args().contains("worktree rerun plotaaaaab \(nativePanel) --json --actor app"))
        #expect(rig.refreshes().count == 2)
        #expect(model.prPopover.note == nil && model.lastError == nil)
    }

    /// The popover closed, or it shows another worktree now, so it cannot say why the button failed. The
    /// error bar of the window says it.
    @Test(arguments: [false, true])
    func aRefusalAfterThePopoverLeftTheWorktreeGoesToTheErrorBar(showsAnother: Bool) async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("fail-rerun")
        try rig.touch("hold-rerun")
        let rerun = Task { await model.rerunFailedChecks() }
        await waitUntil("the re-run runs") { model.prPopover.running == .rerunFailed && rig.calls(of: "rerun") == 1 }
        if showsAnother { model.openPullRequest("wtreaaaaag") } else { model.closePullRequest() }
        await idle(model)
        let refreshes = rig.refreshes().count
        rig.remove("hold-rerun")
        await rerun.value
        #expect(model.lastError == "the origin of /tmp/loam-contract/repos/web is not on GitHub")
        #expect(model.prPopover.note == nil)
        #expect(rig.refreshes().count == refreshes)
    }

    /// The popover closed and opened again on the worktree while Re-run failed runs. The button still runs,
    /// so a second press does nothing, and the note of the run shows in the new popover.
    @Test func aPopoverThatOpensAgainDuringARunShowsTheButtonRunning() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold-rerun")
        let rerun = Task { await model.rerunFailedChecks() }
        await waitUntil("the re-run runs") { model.prPopover.running == .rerunFailed && rig.calls(of: "rerun") == 1 }
        model.closePullRequest()
        model.openPullRequest(nativePanel)
        #expect(model.prPopover.running == .rerunFailed)
        await model.rerunFailedChecks()
        await model.updateBranch()
        #expect(rig.calls(of: "rerun") == 1 && rig.calls(of: "update") == 0)
        rig.remove("hold-rerun")
        await rerun.value
        #expect(model.prPopover.running == nil)
        #expect(model.prPopover.note?.hasPrefix("GitHub runs the failed checks of 1 run again.") == true)
        await idle(model)
    }

    /// The button of one worktree does not stop the button of another.
    @Test func aButtonRunsForItsOwnWorktree() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold-rerun")
        let rerun = Task { await model.rerunFailedChecks() }
        await waitUntil("the re-run runs") { model.prPopover.running == .rerunFailed && rig.calls(of: "rerun") == 1 }
        model.openPullRequest("wtreaaaaak")  // Behind base, #18.
        #expect(model.prPopover.running == nil)
        await model.updateBranch()
        #expect(model.prPopover.note == "GitHub brought the PR up to date with main.")
        rig.remove("hold-rerun")
        await rerun.value
        #expect(model.prPopover.note == "GitHub brought the PR up to date with main.")
        await idle(model)
    }

    /// A refresh that started before the button ended has the state from before the change. The popover
    /// waits for it and then asks again.
    @Test func theRefreshAfterAButtonStartsAfterTheButtonEnded() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest(nativePanel)
        await idle(model)
        try rig.touch("hold-rerun")
        let rerun = Task { await model.rerunFailedChecks() }
        await waitUntil("the re-run runs") { model.prPopover.running == .rerunFailed && rig.calls(of: "rerun") == 1 }
        try rig.touch("hold-2")
        let menu = Task { await model.refreshWorktree(nativePanel) }
        await waitUntil("the second refresh started") { rig.refreshes().count == 2 }
        rig.remove("hold-rerun")
        await waitUntil("the re-run ended") { model.prPopover.running == nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.refreshes().count == 2)
        rig.remove("hold-2")
        await rerun.value
        _ = await menu.value
        #expect(rig.refreshes().count == 3)
    }

    /// Exit 16 and exit 17 are refusals of the core. The open popover says them where the button is.
    @Test func aRefusalOfTheCoreShowsInTheOpenPopover() async throws {
        let rig = try await rig()
        let model = rig.model
        model.openPullRequest("wtreaaaaak")
        await idle(model)
        try rig.touch("fail-update", "16")
        await model.updateBranch()
        #expect(model.prPopover.note == "web-new-api is not ready to land: the PR has conflicts with main")
        try rig.touch("fail-update", "17")
        await model.updateBranch()
        #expect(model.prPopover.note == "the origin of /tmp/loam-contract/repos/web is not on GitHub")
        #expect(model.prPopover.running == nil && model.lastError == nil)
        #expect(rig.refreshes().count == 1)
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

    /// The passed checks show in the card only on a click of their row (ticket 116), and each open is a new card, so
    /// the list is closed on each open and when the popover closes.
    @Test func thePassedChecksOpenOnARequestAndCloseWithTheOpen() async throws {
        let rig = try await rig()
        let model = rig.model
        model.prPopover.togglePassedChecks()
        #expect(!model.prPopover.showsPassedChecks)  // No popover is open.
        model.openPullRequest(nativePanel)
        await idle(model)
        #expect(!model.prPopover.showsPassedChecks)
        model.prPopover.togglePassedChecks()
        #expect(model.prPopover.showsPassedChecks)
        await model.rerunFailedChecks()
        #expect(model.prPopover.showsPassedChecks)  // A button and its refresh leave the list open.
        model.prPopover.togglePassedChecks()
        #expect(!model.prPopover.showsPassedChecks)
        model.prPopover.togglePassedChecks()
        model.openPullRequest("wtreaaaaag")
        #expect(!model.prPopover.showsPassedChecks)
        model.prPopover.togglePassedChecks()
        model.closePullRequest()
        model.openPullRequest(nativePanel)
        #expect(!model.prPopover.showsPassedChecks)
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

    /// The pane header shows the branch from the pane spec, and then the number of the PR mark.
    @Test func thePaneHeaderShowsTheBranchAndThenThePRNumber() async throws {
        let rig = try await rig()
        let model = rig.model
        func header() throws -> [String?] {
            let pane = try #require(model.workspace.focusedPane)
            return [model.workspace.spec(of: pane)?.worktree?.branch, model.pullRequestMark(of: pane)?.label]
        }
        model.openTab(.shell, worktree: try workspaceRef(nativePanel, in: model))
        #expect(try header() == ["native-panel", "#16"])
        let local = try #require(model.worktrees[plotID]?.first { $0.stage == .notPushed })
        model.openTab(.shell, worktree: WorktreeRef(local.worktree))
        #expect(try header() == ["local-work", nil])
        model.openTab(.shell)
        #expect(try header() == [nil, nil])
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
