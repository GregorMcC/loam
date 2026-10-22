import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: a worktree that started from a link shows the issue key on its sidebar row and in line 2 of its Worktrees row,
/// and its goal is the tooltip of the sidebar row. The data is made up.
@Suite struct WorktreeGoalRowTests {
    /// The rows of the `worktree_list_stages` fixture, as a list of statuses.
    func rows() throws -> [WorktreeStatus] {
        try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
    }

    /// A worktree with no PR and a clean checkout, with a goal and the link of a Linear issue.
    func local(key: String = "ENG-482", goal: String? = "Link kinds for Figma") throws -> WorktreeStatus {
        var status = try #require(try rows().first { $0.stage == .notPushed })
        status.pr = nil
        status.changed = 0
        status.unpushed = 0
        status.worktree.goal = goal
        status.worktree.link = WorktreeLink(target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma",
                                            label: "ENG-482 Link kinds for Figma", key: key, linkID: "")
        return status
    }

    // MARK: Worktrees row

    @Test func lineTwoStartsWithTheKeyUntilThereIsAPR() throws {
        var status = try local()
        #expect(StatusLine(of: status, includesLinkKey: true).text == "ENG-482 \u{00B7} No changes")
        status.unpushed = 4
        #expect(StatusLine(of: status, includesLinkKey: true).text == "ENG-482 \u{00B7} 4 commits not pushed")
        // The key is part of the line, and not failing.
        #expect(StatusLine(of: status, includesLinkKey: true).parts.allSatisfy { !$0.failing })
    }

    @Test func theLineHasNoKeyUnlessAViewAsksForIt() throws {
        let status = try local()
        #expect(StatusLine(of: status).text == "No changes")
    }

    @Test func aWorktreeWithNoKeyKeepsItsLine() throws {
        // A link that is not an issue has an empty key.
        #expect(StatusLine(of: try local(key: ""), includesLinkKey: true).text == "No changes")
        var none = try local()
        none.worktree.link = nil
        #expect(StatusLine(of: none, includesLinkKey: true).text == "No changes")
    }

    @Test func aPRLineHasNoKey() throws {
        var status = try #require(try rows().first { $0.stage == .checksFailed })
        status.worktree.link = WorktreeLink(target: "https://linear.app/example/issue/ENG-482", label: "ENG-482", key: "ENG-482", linkID: "")
        #expect(!StatusLine(of: status, includesLinkKey: true).text.contains("ENG-482"))
        #expect(StatusLine(of: status, includesLinkKey: true) == StatusLine(of: status))
    }

    @Test func aFolderThatIsGoneHasNoKey() throws {
        var status = try local()
        status.missing = true
        #expect(StatusLine(of: status, includesLinkKey: true).text == "Folder is gone")
    }

    // MARK: Sidebar row

    @Test func theSidebarRowHasTheKeyAndTheGoal() throws {
        let status = try local()
        var workspace = Workspace()
        let ref = WorktreeRef(id: status.worktree.id, name: status.worktree.name, branch: status.worktree.branch,
                              path: status.worktree.path)
        workspace.openTab(PaneSpec(kind: .session, space: .plot(status.worktree.plotID), title: "claude", worktree: ref))
        let plot = PlotSummary(id: status.worktree.plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")
        let model = SidebarModel(plots: [plot], workspace: workspace, collapsed: false,
                                 worktrees: [status.worktree.plotID: [status]])
        let row = try #require(model.worktreeRows[status.worktree.plotID]?.first)
        #expect(row.linkKey == "ENG-482")
        #expect(row.goal == "Link kinds for Figma")
    }

    @Test func aRowWithNoLinkAndNoGoalHasNeither() throws {
        var status = try local(key: "", goal: "")
        status.worktree.link = nil
        let plot = PlotSummary(id: status.worktree.plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")
        let model = SidebarModel(plots: [plot], workspace: Workspace(), collapsed: false,
                                 worktrees: [status.worktree.plotID: [status]])
        let row = try #require(model.worktreeRows[status.worktree.plotID]?.first)
        #expect(row.linkKey == nil && row.goal == nil)
        // A core before ticket 114 sends neither.
        status.worktree.goal = nil
        let old = SidebarModel(plots: [plot], workspace: Workspace(), collapsed: false, worktrees: [status.worktree.plotID: [status]])
        #expect(old.worktreeRows[status.worktree.plotID]?.first?.goal == nil)
    }
}
