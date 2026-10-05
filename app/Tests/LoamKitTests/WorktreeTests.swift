import Foundation
import Testing

@testable import LoamKit

private let worktreePath = "/tmp/loam-contract/loamhome/worktrees/plotaaaaab/web-fix-login"

private func worktree(id: String = "wtreaaaaab", path: String = worktreePath) -> Worktree {
    Worktree(id: id, plotID: "plotaaaaab", repo: "/tmp/loam-contract/repos/web", name: "fix-login",
             branch: "fix-login", base: "origin/main", path: path, setupDone: false, createdAt: "2026-01-01T00:00:00Z")
}

private func status(changed: Int = 0, unpushed: Int = 0, merged: Bool = true, mergedInto: String? = "origin/main",
                    missing: Bool = false, error: String? = nil) -> WorktreeStatus {
    WorktreeStatus(worktree: worktree(), missing: missing, changed: changed, unpushed: unpushed,
                   merged: merged, mergedInto: mergedInto, error: error)
}

@Suite struct WorktreeRulesTests {
    @Test func aFolderInsideTheWorktreeCounts() {
        #expect(WorktreeRules.contains(worktreePath: worktreePath, folder: worktreePath))
        #expect(WorktreeRules.contains(worktreePath: worktreePath, folder: worktreePath + "/src/app"))
        #expect(WorktreeRules.contains(worktreePath: worktreePath + "/", folder: worktreePath + "/src"))
    }

    @Test func aSiblingWithTheSamePrefixDoesNotCount() {
        #expect(!WorktreeRules.contains(worktreePath: worktreePath, folder: worktreePath + "-2"))
        #expect(!WorktreeRules.contains(worktreePath: worktreePath, folder: "/tmp/loam-contract/repos/web"))
    }

    @Test func aSymbolicLinkToTheWorktreeCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(WorktreeRules.contains(worktreePath: real.path, folder: link.path))
        #expect(WorktreeRules.contains(worktreePath: link.path, folder: real.path))
    }

    @Test func countsTheFoldersInAWorktree() {
        let folders = [worktreePath, worktreePath + "/api", "/tmp/other", worktreePath + "-2"]
        #expect(WorktreeRules.count(in: worktree(), folders: folders) == 2)
    }

    @Test func openPanesRefuseBeforeAnyOtherCheck() {
        let plan = WorktreeRules.plan(for: status(changed: 3, unpushed: 2), openPanes: 1, savedPanes: 0)
        #expect(plan == .refusedOpenPanes(open: 1, saved: 0))
        #expect(!plan.needsConfirmation)
    }

    @Test func savedPanesThatHaveNotResumedRefuseToo() {
        let plan = WorktreeRules.plan(for: status(), openPanes: 0, savedPanes: 2)
        #expect(plan == .refusedOpenPanes(open: 0, saved: 2))
        #expect(plan.message(for: worktree()) == "2 saved panes have not resumed. Close them first.")
    }

    @Test func theRefusalNamesOpenAndSavedPanes() {
        let plan = WorktreeRules.plan(for: status(), openPanes: 2, savedPanes: 1)
        #expect(plan.message(for: worktree()) ==
            "2 panes are open in the worktree fix-login. 1 saved pane has not resumed. Close them first.")
        let one = WorktreeRules.plan(for: status(), openPanes: 1, savedPanes: 0)
        #expect(one.message(for: worktree()) == "1 pane is open in the worktree fix-login. Close it first.")
    }

    @Test func changesOrUnpushedCommitsNeedAForce() {
        let plan = WorktreeRules.plan(for: status(changed: 3, unpushed: 1), openPanes: 0, savedPanes: 0)
        #expect(plan == .needsForce(changed: 3, unpushed: 1, checkError: nil))
        #expect(plan.needsConfirmation)
        #expect(plan.message(for: worktree()) ==
            "In the worktree fix-login, 3 files have uncommitted changes and 1 commit is not pushed. Removing it loses that work.")
    }

    @Test func aFailedCheckNeedsAForceToo() {
        let plan = WorktreeRules.plan(for: status(error: "git failed"), openPanes: 0, savedPanes: 0)
        #expect(plan == .needsForce(changed: 0, unpushed: 0, checkError: "git failed"))
        #expect(plan.message(for: worktree()).contains("A check failed: git failed."))
    }

    @Test func aCleanWorktreeSaysWhereTheBranchStands() {
        #expect(WorktreeRules.plan(for: status(), openPanes: 0, savedPanes: 0)
            == .ready(mergeNote: "The branch is merged into origin/main."))
        #expect(WorktreeRules.plan(for: status(merged: false), openPanes: 0, savedPanes: 0)
            == .ready(mergeNote: "The branch is not merged into origin/main. Loam keeps the local branch."))
        #expect(WorktreeRules.plan(for: status(mergedInto: nil), openPanes: 0, savedPanes: 0)
            == .ready(mergeNote: "Loam cannot tell if the branch is merged."))
    }

    @Test func aGoneFolderGivesTheEndedNote() {
        let ref = WorktreeRef(worktree())
        #expect(WorktreeRules.endedNote(for: ref, status: status(missing: true))?.contains("fix-login is gone") == true)
        #expect(WorktreeRules.endedNote(for: ref, status: nil) != nil)
        #expect(WorktreeRules.endedNote(for: ref, status: status()) == nil)
    }
}

@MainActor
@Suite struct WorktreeModelTests {
    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: id, what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    /// A model that has read the one worktree of the fixture.
    func model(_ fake: FakeLoam) async -> AppModel {
        let model = AppModel(client: fake.client())
        model.shell = "/bin/zsh"
        model.apply([plot("plotaaaaab")])
        await model.reloadWorktrees()
        return model
    }

    @Test func startsASessionWithTheWorktreeFlag() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        let wt = model.worktreeStatus("wtreaaaaab")!.worktree
        model.openWorktreePane(wt)
        let pane = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        let spec = model.workspace.spec(of: pane)!
        #expect(spec.kind == .session)
        #expect(spec.worktree == WorktreeRef(wt))
        #expect(spec.command?.contains("start plotaaaaab --worktree wtreaaaaab --session-id") == true)
    }

    @Test func resumeAndNewSessionKeepTheWorktree() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        model.openWorktreePane(model.worktreeStatus("wtreaaaaab")!.worktree)
        let pane = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        let id = model.workspace.spec(of: pane)!.sessionID!
        model.apply(paneEvent("SessionStart", id, source: "startup"), to: pane)
        model.paneExited(pane)
        model.resumeSession(in: pane)
        #expect(model.workspace.spec(of: pane)?.worktree?.id == "wtreaaaaab")
        #expect(model.workspace.spec(of: pane)?.command?.contains("resume") == true)
        model.paneExited(pane)
        model.newSession(in: pane)
        #expect(model.workspace.spec(of: pane)?.command?.contains("--worktree wtreaaaaab") == true)
    }

    @Test func theSidebarListsWorktreesWithTheirPaneCount() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        #expect(model.sidebar.worktreeRows["plotaaaaab"]?.first?.paneCount == 0)
        model.openWorktreePane(model.worktreeStatus("wtreaaaaab")!.worktree)
        let row = model.sidebar.worktreeRows["plotaaaaab"]?.first
        #expect(row?.branch == "fix-login")
        #expect(row?.paneCount == 1)
    }

    @Test func removalIsRefusedWhileAPaneIsOpen() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        model.openWorktreePane(model.worktreeStatus("wtreaaaaab")!.worktree)
        let plan = await model.planRemoval(of: "wtreaaaaab")
        #expect(plan == .refusedOpenPanes(open: 1, saved: 0))
    }

    @Test func removalIsRefusedForASavedPaneThatHasNotResumed() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        model.savedPaneFolders = { [worktreePath + "/sub"] }
        let plan = await model.planRemoval(of: "wtreaaaaab")
        #expect(plan == .refusedOpenPanes(open: 0, saved: 1))
    }

    @Test func aShellInAWorktreeFolderStopsRemovalToo() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        model.openTab(.shell, folder: worktreePath + "/src")
        #expect(await model.planRemoval(of: "wtreaaaaab") == .refusedOpenPanes(open: 1, saved: 0))
    }

    @Test func aCleanWorktreeIsReadyAndRemovalPassesThePaneFolders() async throws {
        let fake = try FakeLoam([("worktree_list", 0), ("worktree_list", 0), ("worktree_rm", 0), ("worktree_list_empty", 0)])
        let model = await model(fake)
        model.savedPaneFolders = { ["/tmp/elsewhere"] }
        model.openTab(.shell, folder: "/tmp/other-shell")
        #expect(await model.planRemoval(of: "wtreaaaaab") == .ready(mergeNote: "The branch is merged into origin/main."))
        #expect(await model.removeWorktree("wtreaaaaab"))
        let args = fake.args().last { $0.hasPrefix("worktree rm") }
        #expect(args == "worktree rm plotaaaaab wtreaaaaab --open-pane /tmp/other-shell --open-pane /tmp/elsewhere --json --actor app")
        #expect(model.worktreeStatus("wtreaaaaab") == nil)
    }

    @Test func aRefusalFromTheCoreSetsTheError() async throws {
        let fake = try FakeLoam([("worktree_list", 0), ("error_generic", 1)])
        let model = await model(fake)
        #expect(await model.removeWorktree("wtreaaaaab", force: true) == false)
        #expect(model.lastError != nil)
        #expect(fake.args().last?.contains("--force") == true)
        #expect(model.worktreeStatus("wtreaaaaab") != nil)
    }

    @Test func aWorktreeThatIsGoneGivesTheEndedNote() async throws {
        let fake = try FakeLoam([("worktree_list", 0)])
        let model = await model(fake)
        model.openWorktreePane(model.worktreeStatus("wtreaaaaab")!.worktree)
        let pane = model.workspace.selectedTab(of: "plotaaaaab")!.focused
        #expect(model.endedNote(of: pane) == nil)
        let gone = try FakeLoam([("worktree_list_empty", 0)])
        let after = AppModel(client: gone.client())
        after.apply([plot("plotaaaaab")])
        after.openWorktreePane(worktree())
        let ended = after.workspace.selectedTab(of: "plotaaaaab")!.focused
        #expect(after.endedNote(of: ended)?.contains("is gone") == true)
    }

    @Test func aNewWorktreeUsesTheMainRepoAndOpensASession() async throws {
        let fake = try FakeLoam([("show_links", 0), ("worktree_new", 0), ("worktree_list", 0)])
        let model = AppModel(client: fake.client())
        model.apply([plot("plotaaaaab")])
        let made = await model.newWorktree(in: "plotaaaaab", named: " fix-login ")
        #expect(made?.branch == "fix-login")
        #expect(fake.args().contains { $0.hasPrefix("worktree new plotaaaaab") && $0.contains(" fix-login --json --actor app") })
        #expect(model.workspace.paneCount(of: "plotaaaaab") == 1)
    }
}
