import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: the app model opens the New worktree sheet, checks the branch as you type, and makes the worktree
/// through `loam`. The fake `loam` logs its arguments. The check prints `check.json`, `worktree new` prints the
/// fixture, and the list is the `worktree_list` fixture (made-up example/widgets data).
@MainActor
@Suite(.waitLimit) struct NewWorktreeFlowTests {
    let plotID = "plotaaaaab"
    let linear = "lnkaaaaaaa"

    @MainActor final class Rig {
        let dir: URL
        let model: AppModel

        init(dir: URL, model: AppModel) {
            self.dir = dir
            self.model = model
        }

        var sheet: NewWorktreeModel { model.newWorktreeSheet }

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func checks() -> [String] { args().filter { $0.hasPrefix("worktree new") && $0.contains("--dry-run") } }
        func makes() -> [String] { args().filter { $0.hasPrefix("worktree new") && !$0.contains("--dry-run") } }
        func write(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }
        func touch(_ name: String, _ text: String = "") throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }

        /// The answer of the next checks.
        func check(_ edit: (inout WorktreeCheck) -> Void = { _ in }) throws {
            var check = try JSONDecoder().decode(WorktreeCheck.self, from: Fixtures.data("worktree_new_dry_run"))
            edit(&check)
            try write("check.json", JSONEncoder().encode(check))
        }

        /// Waits for the read of the plot and the check after it.
        func settle() async {
            await sheet.reading?.value
            await sheet.checking?.value
            await sheet.queuedStart?.value
        }

        /// Waits until `worktree new` runs for the sheet.
        func waitForStarting(sourceLocation: SourceLocation = #_sourceLocation) async {
            await waitUntil("the start began", sourceLocation: sourceLocation) { sheet.isStarting }
        }
    }

    func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("newworktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["worktree_list", "worktree_new", "worktree_edit", "error_invalid", "error_stale_worktree"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        var show = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
        show["repos"] = [["id": "repoaaaaaa", "path": "/tmp/example/widgets", "note": "", "main": true, "version": 1]]
        show["links"] = [["id": linear, "kind": "linear", "label": "ENG-482 Link kinds for Figma", "note": "", "position": 1,
                          "target": "https://linear.app/example/issue/ENG-482/link-kinds-for-figma", "version": 3]]
        try JSONSerialization.data(withJSONObject: show).write(to: dir.appendingPathComponent("show.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1 $2" in
              "show "*) cat '\(d)/show.json';;
              "worktree new")
                case "$*" in
                  *--dry-run*) [ -f '\(d)/fail-check' ] && { cat '\(d)/error_invalid.json'; exit 2; }
                    cat '\(d)/check.json';;
                  *) while [ -f '\(d)/hold-new' ]; do sleep 0.01; done
                    [ -f '\(d)/fail-new' ] && { cat '\(d)/error_invalid.json'; exit 2; }
                    touch '\(d)/made'
                    cat '\(d)/worktree_new.json';;
                esac;;
              "worktree edit") [ -f '\(d)/fail-edit' ] && { cat '\(d)/error_stale_worktree.json'; exit 10; }
                cat '\(d)/worktree_edit.json';;
              "worktree list") cat '\(d)/worktree_list.json';;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        let rig = Rig(dir: dir, model: model)
        rig.sheet.checkDelay = .milliseconds(5)
        try rig.check()
        return rig
    }

    var linearLink: PlotLink {
        PlotLink(id: linear, label: "ENG-482 Link kinds for Figma",
                 target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma", note: "", position: 1, version: 3,
                 kind: .linear, exists: nil)
    }

    // MARK: Open and check

    @Test func openingReadsThePlotAndChecksTheBranchFromTheLink() async throws {
        let rig = try await rig()
        #expect(rig.model.openNewWorktree(plot: plotID, from: linearLink))
        #expect(rig.sheet.isOpen && rig.sheet.phase == .loading)
        #expect(rig.sheet.branch == "eng-482-link-kinds-for-figma", "the fields are filled before the plot is back")
        await rig.settle()
        #expect(rig.sheet.phase == .ready)
        #expect(rig.sheet.repoID == "repoaaaaaa")
        #expect(rig.args().first == "show \(plotID) --json")
        #expect(rig.checks() == [
            "worktree new --dry-run --goal Link kinds for Figma --link \(linear) --json -- \(plotID) repoaaaaaa eng-482-link-kinds-for-figma",
        ])
        #expect(rig.sheet.branchState == .new)
        #expect(rig.sheet.bases == ["origin/main", "main"])
        #expect(rig.sheet.seedLine?.hasPrefix("- web-fix-login") == true)
    }

    @Test func thePlusChecksTheEmptyNameForTheBases() async throws {
        let rig = try await rig()
        #expect(rig.model.openNewWorktree(plot: plotID))
        await rig.settle()
        #expect(rig.checks() == ["worktree new --dry-run --json -- \(plotID) repoaaaaaa "])
        #expect(rig.sheet.branchState == .empty)
        #expect(rig.sheet.bases == ["origin/main", "main"])
    }

    @Test func aBurstOfKeysAsksTheCoreOnce() async throws {
        let rig = try await rig()
        rig.sheet.checkDelay = .milliseconds(60)
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        let before = rig.checks().count
        for text in ["f", "fi", "fix", "fix-", "fix-l"] { rig.sheet.setBranch(text) }
        await rig.sheet.checking?.value
        let asked = Array(rig.checks().dropFirst(before))
        #expect(asked == ["worktree new --dry-run --json -- \(plotID) repoaaaaaa fix-l"])
        #expect(rig.sheet.branchState == .new)
    }

    @Test func aFailedCheckShowsTheMessageAndBlocksStart() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        try rig.touch("fail-check")
        await rig.settle()
        guard case .failed(let message) = rig.sheet.branchState else {
            Issue.record("the state is \(rig.sheet.branchState)")
            return
        }
        #expect(message.contains("choose a number"))
        #expect(!rig.sheet.canStart)
        await rig.model.startNewWorktree()
        #expect(rig.makes().isEmpty)
    }

    @Test func aPlotThatCannotBeReadFails() async throws {
        let rig = try await rig()
        try rig.touch("show.json", "not json")
        rig.model.openNewWorktree(plot: plotID)
        await rig.sheet.reading?.value
        if case .failed = rig.sheet.phase {} else { Issue.record("the phase is \(rig.sheet.phase)") }
        #expect(rig.checks().isEmpty && !rig.sheet.canStart)
    }

    @Test func aCloseDropsTheLateAnswers() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        rig.model.closeNewWorktree()
        await rig.settle()
        #expect(!rig.sheet.isOpen)
        #expect(rig.sheet.phase == .loading, "the read of the old open did not fill the closed sheet")
        #expect(rig.sheet.repos.isEmpty)
    }

    // MARK: Start

    @Test func startSessionMakesTheWorktreeWithTheGoalAndTheLinkAndOpensASession() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        await rig.model.startNewWorktree()
        #expect(rig.makes() == [
            "worktree new --goal Link kinds for Figma --link \(linear) --json --actor app "
                + "-- \(plotID) repoaaaaaa eng-482-link-kinds-for-figma",
        ])
        #expect(!rig.sheet.isOpen)
        #expect(rig.model.workspace.paneCount(of: .plot(plotID)) == 1, "a seeded session opens in the new worktree")
        let pane = try #require(rig.model.workspace.focusedPane)
        #expect(rig.model.workspace.spec(of: pane)?.worktree?.id == "wtreaaaaab")
    }

    @Test func aBaseThatYouChoseGoesToTheNewBranchOnly() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        rig.sheet.setBranch("fix-login")
        rig.sheet.chooseBase("main")
        await rig.sheet.checking?.value
        #expect(rig.checks().last == "worktree new --dry-run --base main --json -- \(plotID) repoaaaaaa fix-login")
        await rig.model.startNewWorktree()
        #expect(rig.makes() == ["worktree new --base main --json --actor app -- \(plotID) repoaaaaaa fix-login"])

        // A branch that exists takes no base: the core refuses one.
        try rig.check { $0.branchExists = true }
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        rig.sheet.setBranch("link-labels")
        rig.sheet.chooseBase("main")
        await rig.sheet.checking?.value
        #expect(rig.sheet.branchState == .exists)
        await rig.model.startNewWorktree()
        #expect(rig.makes().last == "worktree new --json --actor app -- \(plotID) repoaaaaaa link-labels")
    }

    @Test func aPastedIssueGoesToTheWorktreeAsAUrl() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        rig.sheet.chooseLink(.pasted)
        rig.sheet.setPastedURL(" https://github.com/example/widgets/issues/57 ")
        await rig.sheet.checking?.value
        #expect(rig.sheet.branch == "57")
        await rig.model.startNewWorktree()
        #expect(rig.makes() == ["worktree new --link https://github.com/example/widgets/issues/57 --json --actor app -- \(plotID) repoaaaaaa 57"])
    }

    @Test func startDoesNothingWhileTheCheckBlocks() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        // Empty branch.
        await rig.model.startNewWorktree()
        // A bad name.
        try rig.check { $0.validName = false; $0.nameError = "bad name"; $0.seedLine = nil }
        rig.sheet.setBranch("a b")
        await rig.sheet.checking?.value
        await rig.model.startNewWorktree()
        // A worktree that is there.
        try rig.check { $0.worktreeExists = true }
        rig.sheet.setBranch("a-b")
        await rig.sheet.checking?.value
        await rig.model.startNewWorktree()
        // The answer is not back.
        try rig.check()
        rig.sheet.checkDelay = .seconds(30)
        rig.sheet.setBranch("a-b-c")
        await rig.model.startNewWorktree()
        rig.sheet.checking?.cancel()
        #expect(rig.makes().isEmpty)
        #expect(rig.sheet.isOpen)
    }

    // MARK: Return never does nothing without a word

    @Test func returnWhileThePlotIsReadStartsWhenTheCheckIsBack() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.model.startNewWorktree()
        #expect(rig.sheet.startQueued)
        #expect(rig.makes().isEmpty)
        await rig.settle()
        #expect(rig.makes().count == 1)
        #expect(!rig.sheet.isOpen && !rig.sheet.startQueued)
    }

    @Test func returnWhileTheBranchIsCheckedStartsWhenTheCheckIsGood() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        rig.sheet.checkDelay = .milliseconds(40)
        rig.sheet.setBranch("fix-login")
        await rig.model.startNewWorktree()
        #expect(rig.sheet.startQueued && rig.makes().isEmpty)
        await rig.sheet.checking?.value
        await rig.sheet.queuedStart?.value
        #expect(rig.makes() == ["worktree new --json --actor app -- \(plotID) repoaaaaaa fix-login"])
    }

    @Test func aQueuedStartDoesNotRunWhenTheCheckRefusesTheName() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        try rig.check { $0.validName = false; $0.nameError = "bad name"; $0.seedLine = nil }
        rig.sheet.checkDelay = .milliseconds(40)
        rig.sheet.setBranch("a b")
        await rig.model.startNewWorktree()
        #expect(rig.sheet.startQueued)
        await rig.sheet.checking?.value
        #expect(rig.makes().isEmpty)
        #expect(!rig.sheet.startQueued, "the note under the field says why")
        #expect(rig.sheet.branchState == .invalid("bad name"))
    }

    @Test func returnRightAfterAGoalEditStartsAtOnce() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        rig.sheet.checkDelay = .seconds(30)
        rig.sheet.setGoal("A new goal")
        await rig.model.startNewWorktree()
        rig.sheet.checking?.cancel()
        #expect(rig.makes() == [
            "worktree new --goal A new goal --link \(linear) --json --actor app -- \(plotID) repoaaaaaa eng-482-link-kinds-for-figma",
        ])
    }

    @Test func aNameThatStartsWithAHyphenIsNeverAsked() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID)
        await rig.settle()
        let before = rig.checks().count
        rig.sheet.setBranch("-h")
        await rig.sheet.checking?.value
        #expect(rig.checks().count == before, "the core is not asked for a name that it refuses")
        await rig.model.startNewWorktree()
        #expect(rig.makes().isEmpty && !rig.sheet.startQueued)
    }

    @Test func aFailureKeepsTheSheetOpenWithTheMessage() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        try rig.touch("fail-new")
        await rig.model.startNewWorktree()
        #expect(rig.sheet.isOpen && !rig.sheet.isStarting)
        #expect(rig.sheet.startError?.contains("choose a number") == true)
        #expect(rig.model.workspace.paneCount(of: .plot(plotID)) == 0)
        // The fields stay, so you can fix them and start again.
        #expect(rig.sheet.branch == "eng-482-link-kinds-for-figma" && rig.sheet.canStart)
    }

    @Test func theSheetStaysWhileTheWorktreeIsMade() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        try rig.touch("hold-new")
        let starting = Task { await rig.model.startNewWorktree() }
        await rig.waitForStarting()
        rig.model.closeNewWorktree()
        #expect(rig.sheet.isOpen, "a worktree that is made now cannot stop")
        // A second Start does not make a second worktree.
        await rig.model.startNewWorktree()
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-new"))
        await starting.value
        #expect(rig.makes().count == 1)
        #expect(!rig.sheet.isOpen)
    }

    // MARK: A worktree that is made is never stopped

    @Test func aQueuedStartIsNotStoppedByANewOpen() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        try rig.touch("hold-new")
        await rig.model.startNewWorktree()
        #expect(rig.sheet.startQueued)
        // The check comes back, and `worktree new` runs and waits.
        await rig.waitForStarting()
        // Start work… on a link, the plus and the menu cannot open the sheet again: that would cancel the check task, and
        // the cancel would end `worktree new` with SIGTERM in the middle of its work.
        #expect(!rig.model.openNewWorktree(plot: plotID, from: linearLink))
        #expect(!rig.model.openNewWorktree(plot: plotID))
        #expect(rig.sheet.isOpen && rig.sheet.isStarting)
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-new"))
        await rig.settle()
        #expect(rig.makes().count == 1)
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("made").path), "worktree new ran to its end")
        #expect(!rig.sheet.isOpen && rig.sheet.startError == nil)
        #expect(rig.model.workspace.paneCount(of: .plot(plotID)) == 1, "the session opened in the new worktree")
    }

    @Test func aQueuedStartRunsInATaskOfItsOwn() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        try rig.touch("hold-new")
        await rig.model.startNewWorktree()
        await rig.waitForStarting()
        // A change of a field asks for a new check, and a new check cancels the one before. The start goes on.
        rig.sheet.checking?.cancel()
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-new"))
        await rig.settle()
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("made").path))
        #expect(!rig.sheet.isOpen)
    }

    @Test func noEntryOpensTheSheetWhileAWorktreeIsMade() async throws {
        let rig = try await rig()
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        try rig.touch("hold-new")
        let starting = Task { await rig.model.startNewWorktree() }
        await rig.waitForStarting()
        #expect(!rig.model.openNewWorktree(plot: plotID))
        #expect(!rig.model.openNewWorktree(plot: plotID, from: linearLink))
        #expect(rig.sheet.isOpen && rig.sheet.isStarting, "a new open does not take back isStarting")
        #expect(rig.sheet.branch == "eng-482-link-kinds-for-figma", "and it keeps the fields")
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-new"))
        await starting.value
        #expect(rig.makes().count == 1 && !rig.sheet.isOpen)
        // With the worktree made, the sheet opens again.
        #expect(rig.model.openNewWorktree(plot: plotID))
    }

    @Test func theSwitcherDoesNotLeaveThePlotWhileAWorktreeIsMade() async throws {
        let rig = try await rig()
        rig.model.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z"),
                         PlotSummary(id: "plotaaaaac", name: "Gadgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        rig.model.openNewWorktree(plot: plotID, from: linearLink)
        await rig.settle()
        rig.model.activate(plot: "plotaaaaac")
        try rig.touch("hold-new")
        let starting = Task { await rig.model.startNewWorktree() }
        await rig.waitForStarting()
        let link = SwitcherLink(plotID: plotID, linkID: linear, label: "ENG-482 Link kinds for Figma",
                                target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma", kind: .linear)
        let item = try #require(SwitcherModel.items(plots: rig.model.plots, workspace: rig.model.workspace, terminalTitles: [:],
                                                    attention: { _ in .none }, savedPanes: [], links: [link], actions: [])
            .first { $0.kind == .link })
        rig.model.switcher.chooseAlternate(item)
        #expect(rig.model.workspace.activeSpace == .plot("plotaaaaac"), "the switcher does not change the plot")
        #expect(rig.sheet.isOpen && rig.sheet.isStarting)
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-new"))
        await starting.value
        #expect(rig.makes().count == 1)
    }

    @Test func noSheetOpensOverAMerge() async throws {
        let rig = try await rig()
        rig.model.landSheet.beginMerging()
        #expect(!rig.model.openNewWorktree(plot: plotID))
        #expect(!rig.sheet.isOpen)
    }

    // MARK: Goal

    @Test func aGoalEditExpectsTheVersionOfTheRow() async throws {
        let rig = try await rig()
        await rig.model.reloadWorktrees()
        let saved = await rig.model.setWorktreeGoal("wtreaaaaab", to: "  Fix the login form on phones ", expect: 0)
        #expect(saved == .saved)
        #expect(rig.args().contains("worktree edit \(plotID) wtreaaaaab --goal Fix the login form on phones --expect worktree:wtreaaaaab=0 --json --actor app"))
    }

    @Test func aGoalThatChangedMeanwhileIsNotOverwritten() async throws {
        let rig = try await rig()
        await rig.model.reloadWorktrees()
        try rig.touch("fail-edit")
        let saved = await rig.model.setWorktreeGoal("wtreaaaaab", to: "Mine", expect: 0)
        #expect(saved == .changed)
    }

    @Test func aWorktreeThatIsGoneHasNoGoalToSet() async throws {
        let rig = try await rig()
        #expect(await rig.model.setWorktreeGoal("nope", to: "x", expect: 0) == .failed("The worktree is gone."))
        #expect(rig.args().allSatisfy { !$0.hasPrefix("worktree edit") })
    }
}
