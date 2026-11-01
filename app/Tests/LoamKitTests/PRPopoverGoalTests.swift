import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: the PR popover of a worktree with no PR has a Goal row that you click to edit, and a Link row that opens
/// the issue. The data is made up (example/widgets). The goal is saved with `loam worktree edit --goal`.
@Suite struct PRPopoverGoalContentTests {
    func status(_ edit: (inout WorktreeStatus) -> Void = { _ in }) throws -> WorktreeStatus {
        var status = try #require(try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list")).first)
        edit(&status)
        return status
    }

    @Test func aWorktreeWithNoPRHasTheGoalAndTheLinkAboveBase() throws {
        let content = PRPopoverContent(try status())
        #expect(content.goal == .init(text: "Fix the login form"))
        #expect(content.link == .init(label: "widgets#57", url: URL(string: "https://github.com/example/widgets/issues/57"),
                                      icon: .link(.github, target: "https://github.com/example/widgets/issues/57")))
        // The rows that follow are the ones of ticket 109.
        #expect(content.rows.map(\.label) == ["Base", "Local"])
    }

    @Test func aLinearIssueShowsTheLinearMark() throws {
        let content = PRPopoverContent(try status {
            $0.worktree.link = WorktreeLink(target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma",
                                            label: "ENG-482 Link kinds for Figma", key: "ENG-482", linkID: "lnkaaaaaaa")
        })
        #expect(content.link?.label == "ENG-482 Link kinds for Figma")
        #expect(content.link?.icon == .brand(.linear))
    }

    @Test func aWorktreeWithNoGoalInvitesOne() throws {
        for goal in [nil, ""] as [String?] {
            let content = PRPopoverContent(try status { $0.worktree.goal = goal })
            #expect(content.goal == .init(text: ""))
        }
        #expect(PRPopoverContent.Goal.placeholder == "Add a goal")
    }

    @Test func aWorktreeWithNoLinkHasNoLinkRow() throws {
        let content = PRPopoverContent(try status { $0.worktree.link = nil })
        #expect(content.link == nil)
        #expect(content.goal != nil)
    }

    @Test func aLinkThatIsNotAWebAddressOnlyNamesItself() throws {
        let content = PRPopoverContent(try status {
            $0.worktree.link = WorktreeLink(target: "/tmp/example/spec.md", label: "spec.md", key: "", linkID: "lnkaaaaaaa")
        })
        #expect(content.link?.url == nil)
        #expect(content.link?.label == "spec.md")
    }

    @Test func aWorktreeWithAPRHasNeither() throws {
        let rows = try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
        let withPR = try #require(rows.first { $0.stage == .checksFailed })
        let content = PRPopoverContent(withPR)
        #expect(content.hasPullRequest && content.goal == nil && content.link == nil)
    }

    @Test func aFolderThatIsGoneHasNeither() throws {
        let content = PRPopoverContent(try status { $0.missing = true })
        #expect(content.goal == nil && content.link == nil)
    }
}

@MainActor
@Suite(.waitLimit) struct PRPopoverGoalEditTests {
    let plotID = "plotaaaaab"
    let id = "wtreaaaaab"

    @MainActor final class Rig {
        let dir: URL
        let model: AppModel
        init(dir: URL, model: AppModel) {
            self.dir = dir
            self.model = model
        }

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func edits() -> [String] { args().filter { $0.hasPrefix("worktree edit") } }
        func touch(_ name: String, _ text: String = "") throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    }

    func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("popover-goal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["worktree_list", "worktree_list_stages", "worktree_edit", "error_stale_worktree", "error_invalid"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        try Fixtures.data("worktree_list").write(to: dir.appendingPathComponent("list.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1 $2" in
              "worktree edit")
                while [ -f '\(d)/hold-edit' ]; do sleep 0.01; done
                [ -f '\(d)/fail-stale' ] && { cat '\(d)/error_stale_worktree.json'; exit 10; }
                [ -f '\(d)/fail-edit' ] && { cat '\(d)/error_invalid.json'; exit 2; }
                cat '\(d)/worktree_edit.json';;
              "worktree list") [ -f '\(d)/fail-list' ] && exit 1
                [ -f '\(d)/fail-list-once' ] && { rm '\(d)/fail-list-once'; exit 1; }
                cat '\(d)/list.json';;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        await model.reloadWorktrees()
        return Rig(dir: dir, model: model)
    }

    @Test func aClickOpensTheGoalForEditAndReturnSavesIt() async throws {
        let rig = try await rig()
        let model = rig.model
        #expect(model.openPullRequest(id))
        #expect(model.prPopover.goalDraft == nil)
        model.beginGoalEdit()
        #expect(model.prPopover.goalDraft == "Fix the login form")
        model.prPopover.setGoalDraft("  Fix the login form on phones ")
        var own: [Int] = []
        model.onOwnChange = { own.append($0) }
        await model.saveGoalEdit()
        #expect(rig.edits() == ["worktree edit \(plotID) \(id) --goal Fix the login form on phones --expect worktree:\(id)=0 --json --actor app"])
        #expect(own == [28], "the action bar is told about the change")
        #expect(model.prPopover.goalDraft == nil && model.prPopover.goalProblem == nil && !model.prPopover.isSavingGoal)
        #expect(model.prPopover.isOpen, "the popover stays")
    }

    @Test func escapeCancelsTheEditAndSavesNothing() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("Something else")
        rig.model.cancelGoalEdit()
        #expect(rig.model.prPopover.goalDraft == nil)
        #expect(rig.edits().isEmpty)
    }

    @Test func aGoalThatYouEmptyIsCleared() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("   ")
        await rig.model.saveGoalEdit()
        #expect(rig.edits() == ["worktree edit \(plotID) \(id) --goal  --expect worktree:\(id)=0 --json --actor app"])
    }

    /// The next list has another goal and version for the worktree, as after a `set_worktree_goal` by Claude.
    func claudeSetsTheGoal(_ rig: Rig, _ goal: String, version: Int) async throws {
        var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list")) as? [[String: Any]])
        var worktree = try #require(rows[0]["worktree"] as? [String: Any])
        worktree["goal"] = goal
        worktree["version"] = version
        rows[0]["worktree"] = worktree
        try JSONSerialization.data(withJSONObject: rows).write(to: rig.dir.appendingPathComponent("list.json"))
        await rig.model.reloadWorktrees()
        #expect(rig.model.worktreeStatus(id)?.worktree.version == version)
    }

    @Test func theSaveExpectsTheVersionThatTheEditOpenedWith() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        // Claude sets the goal while you type. The row has the new version now, but the edit read the old one.
        try await claudeSetsTheGoal(rig, "Claude's goal", version: 40)
        #expect(rig.model.prPopover.goalDraft == "Fix the login form", "the edit keeps its draft")
        rig.model.prPopover.setGoalDraft("Mine")
        await rig.model.saveGoalEdit()
        #expect(rig.edits() == ["worktree edit \(plotID) \(id) --goal Mine --expect worktree:\(id)=0 --json --actor app"])
    }

    @Test func aGoalThatChangedMeanwhileShowsTheNewGoalAndNotYourDraft() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        try await claudeSetsTheGoal(rig, "Claude's goal", version: 40)
        rig.model.prPopover.setGoalDraft("Mine")
        try rig.touch("fail-stale")
        await rig.model.saveGoalEdit()
        // The field shows the goal that you never saw, with the message. A second Return must not overwrite it.
        #expect(rig.model.prPopover.goalDraft == "Claude's goal")
        #expect(rig.model.prPopover.goalProblem == "The goal changed meanwhile. Loam shows the new goal.")
        #expect(!rig.model.prPopover.isSavingGoal)
        // A key in the field takes the message away, and the next save expects the version that the field shows.
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("fail-stale"))
        rig.model.prPopover.setGoalDraft("Claude's goal, and mine")
        #expect(rig.model.prPopover.goalProblem == nil)
        await rig.model.saveGoalEdit()
        #expect(rig.edits().last == "worktree edit \(plotID) \(id) --goal Claude's goal, and mine --expect worktree:\(id)=40 --json --actor app")
        #expect(rig.model.prPopover.goalDraft == nil)
    }

    /// The row that the next read gives, as after a `set_worktree_goal` by Claude. It does not read the list.
    func writeList(_ rig: Rig, goal: String, version: Int) throws {
        var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list")) as? [[String: Any]])
        var worktree = try #require(rows[0]["worktree"] as? [String: Any])
        worktree["goal"] = goal
        worktree["version"] = version
        rows[0]["worktree"] = worktree
        try JSONSerialization.data(withJSONObject: rows).write(to: rig.dir.appendingPathComponent("list.json"))
    }

    @Test func aStaleAnswerWithNoNewReadKeepsYourDraftAndNeverShowsTheOldGoalAsNew() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("Mine")
        // Claude sets the goal, but the read after the stale answer fails: the row is still the one that the edit opened with.
        try writeList(rig, goal: "Claude's goal", version: 40)
        try rig.touch("fail-stale")
        try rig.touch("fail-list")
        await rig.model.saveGoalEdit()
        #expect(rig.model.worktreeStatus(id)?.worktree.version == 0)
        #expect(rig.model.prPopover.goalDraft == "Mine", "the draft stays")
        #expect(rig.model.prPopover.goalProblem?.contains("could not read") == true)
        #expect(!rig.model.prPopover.isSavingGoal && rig.model.prPopover.goalDraft != "Fix the login form")
        // The read works again. The next Return gets a stale answer again, and now the field shows the new goal.
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("fail-list"))
        await rig.model.saveGoalEdit()
        #expect(rig.model.prPopover.goalDraft == "Claude's goal")
        #expect(rig.model.prPopover.goalProblem == "The goal changed meanwhile. Loam shows the new goal.")
        #expect(rig.model.prPopover.goalVersion == 40)
    }

    @Test func aStaleAnswerShowsTheNewGoalEvenWhenTheSharedReadDidNotApply() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("Mine")
        // The shared read fails once (the read of the stale answer), then reads fine: the second read finds the new row.
        try writeList(rig, goal: "Claude's goal", version: 40)
        try rig.touch("fail-stale")
        try rig.touch("fail-list-once")
        await rig.model.saveGoalEdit()
        #expect(rig.model.prPopover.goalDraft == "Claude's goal")
        #expect(rig.model.prPopover.goalVersion == 40)
        #expect(rig.model.prPopover.goalProblem == "The goal changed meanwhile. Loam shows the new goal.")
    }

    @Test func anyOtherFailureKeepsTheEditOpenWithTheMessageOfTheCore() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("Mine")
        try rig.touch("fail-edit")
        await rig.model.saveGoalEdit()
        #expect(rig.model.prPopover.goalDraft == "Mine")
        #expect(rig.model.prPopover.goalProblem?.contains("choose a number") == true)
    }

    /// After a save, the field takes the keys again and writes its text back with no change. The message stays until you
    /// change the text, so you can read why Return did not save.
    @Test func theMessageStaysUntilTheTextChanges() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        try await claudeSetsTheGoal(rig, "Claude's goal", version: 40)
        rig.model.prPopover.setGoalDraft("Mine")
        try rig.touch("fail-stale")
        await rig.model.saveGoalEdit()
        let message = "The goal changed meanwhile. Loam shows the new goal."
        #expect(rig.model.prPopover.goalProblem == message)
        rig.model.prPopover.setGoalDraft("Claude's goal")
        #expect(rig.model.prPopover.goalProblem == message, "a write of the same text took the message away")
        rig.model.prPopover.setGoalDraft("Claude's goal!")
        #expect(rig.model.prPopover.goalProblem == nil)
    }

    @Test func aWorktreeWithAPRHasNoGoalToEdit() async throws {
        let rig = try await rig()
        try Fixtures.data("worktree_list_stages").write(to: rig.dir.appendingPathComponent("list.json"))
        await rig.model.reloadWorktrees()
        let withPR = try #require(rig.model.worktrees[plotID]?.first { $0.pr != nil })
        rig.model.openPullRequest(withPR.worktree.id)
        rig.model.beginGoalEdit()
        #expect(rig.model.prPopover.goalDraft == nil)
    }

    @Test func theEditGoesWhenThePopoverClosesOrOpensAgain() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.closePullRequest()
        #expect(rig.model.prPopover.goalDraft == nil)
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.openPullRequest(id)
        #expect(rig.model.prPopover.goalDraft == nil, "a new open is a new card")
    }

    @Test func theEditGoesWhenTheWorktreeGetsAPR() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        // The next list gives the worktree a PR.
        var rows = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("worktree_list_stages")) as? [[String: Any]])
        var row = try #require(rows.first { ($0["pr"] as? [String: Any]) != nil })
        var worktree = try #require(row["worktree"] as? [String: Any])
        worktree["id"] = id
        worktree["plot_id"] = plotID
        row["worktree"] = worktree
        try JSONSerialization.data(withJSONObject: [row]).write(to: rig.dir.appendingPathComponent("list.json"))
        await rig.model.reloadWorktrees()
        #expect(rig.model.worktreeStatus(id)?.pr != nil)
        #expect(rig.model.prPopover.goalDraft == nil)
    }

    @Test func aSaveThatEndsAfterTheCloseChangesNothing() async throws {
        let rig = try await rig()
        rig.model.openPullRequest(id)
        rig.model.beginGoalEdit()
        rig.model.prPopover.setGoalDraft("Mine")
        try rig.touch("hold-edit")
        let saving = Task { await rig.model.saveGoalEdit() }
        await waitUntil("the save started") { rig.model.prPopover.isSavingGoal }
        // The field is locked while the save runs.
        rig.model.prPopover.setGoalDraft("Other")
        #expect(rig.model.prPopover.goalDraft == "Mine")
        rig.model.closePullRequest()
        try FileManager.default.removeItem(at: rig.dir.appendingPathComponent("hold-edit"))
        await saving.value
        #expect(rig.model.prPopover.goalDraft == nil && !rig.model.prPopover.isSavingGoal)
        #expect(rig.edits().count == 1)
    }
}
