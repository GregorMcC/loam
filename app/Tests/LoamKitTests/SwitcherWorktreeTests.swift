import Foundation
import Testing

@testable import LoamKit

/// Ticket 109: a worktree with a PR is an item of the quick switcher. "#16" or a word of the PR title
/// finds it. The worktrees come from the `worktree_list_stages` fixture (made-up example/widgets data).
@MainActor
@Suite(.temporaryFolders) struct SwitcherWorktreeTests {
    let plots = [PlotSummary(id: "plotaaaaab", name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")]

    func rows() throws -> [WorktreeStatus] {
        try JSONDecoder().decode([WorktreeStatus].self, from: Fixtures.data("worktree_list_stages"))
    }

    func items(_ rows: [WorktreeStatus], plots: [PlotSummary]? = nil) -> [SwitcherItem] {
        SwitcherModel.items(plots: plots ?? self.plots, workspace: Workspace(), terminalTitles: [:], attention: { _ in .none },
                            savedPanes: [], worktrees: rows, links: [], actions: [])
    }

    @Test func aWorktreeWithAPRIsAnItem() throws {
        let rows = try rows()
        let native = try #require(rows.first { $0.stage == .checksFailed })
        let item = try #require(items(rows).first { $0.target == .worktree(native.worktree.id) })
        #expect(item.id == "worktree:\(native.worktree.id)" && item.kind == .worktree)
        #expect(item.title == "native-panel")
        #expect(item.otherText == ["#16", "Native panel", "Widgets"])
        #expect(item.plotName == "Widgets" && item.accessory == "Worktree" && item.icon == .symbol("arrow.triangle.pull"))
        #expect(item.kind.heading == "Worktrees" && item.kind.label == "WORKTREE")
    }

    @Test func onlyWorktreesWithAPRAndAFolderAreItems() throws {
        var rows = try rows()
        let withPR = rows.filter { $0.pr != nil }.map(\.worktree.id)
        #expect(Set(items(rows).filter { $0.kind == .worktree }.map(\.id)) == Set(withPR.map(SwitcherItem.worktreeKey)))
        #expect(withPR.count < rows.count)
        rows[rows.firstIndex { $0.worktree.id == withPR[0] }!].missing = true
        #expect(!items(rows).contains { $0.target == .worktree(withPR[0]) })
    }

    @Test func aWorktreeOfAnArchivedPlotIsNoItem() throws {
        let other = [PlotSummary(id: "plotzzzzzz", name: "Other", what: "", createdAt: "2026-01-01T00:00:00Z")]
        #expect(items(try rows(), plots: other).allSatisfy { $0.kind != .worktree })
    }

    @Test func theNumberAndTheTitleFindTheWorktree() throws {
        let all = items(try rows())
        func found(_ query: String) -> [String] {
            SwitcherRanker.rank(all, query: query, useTimes: [:]).filter { $0.item.kind == .worktree }.map(\.item.title)
        }
        #expect(found("#16") == ["native-panel"])
        #expect(found("native") == ["native-panel"])
        // A word of the PR title that the branch does not have.
        #expect(found("labels") == ["link-labels"])
        #expect(found("zzz").isEmpty)
    }

    @Test func aWorktreeShowsOnlyAfterYouType() throws {
        let all = items(try rows())
        #expect(SwitcherRanker.rank(all, query: "", useTimes: [:]).allSatisfy { $0.item.kind != .worktree })
        #expect(SwitcherRanker.rank(all, query: ">", useTimes: [:]).allSatisfy { $0.item.kind == .action })
    }

    // MARK: The preview

    @Test func thePreviewNamesThePRAndItsStatus() throws {
        let rows = try rows()
        let native = try #require(rows.first { $0.stage == .checksFailed })
        let item = try #require(items(rows).first { $0.target == .worktree(native.worktree.id) })
        let context = SwitcherPreview.Context(plots: [:], panes: [], changes: [], checkouts: [:], actorText: { _ in "" },
                                              clock: { _ in "" }, home: "/Users/me", worktrees: rows)
        let preview = SwitcherPreview.make(for: item, in: context)
        #expect(preview.caption == "Worktree \u{00B7} Checks failed" && preview.footerAction == "Show pull request")
        #expect(preview.rows.map(\.label) == ["Plot", "Pull request", "Status", "Folder"])
        #expect(preview.rows[1].value == .text("#16 Native panel"))
        #expect(preview.rows[2].value == .text(StatusLine(of: native).text))
        #expect(SwitcherPreview.subtitle(for: item, in: context) == "Widgets")
    }

    @Test func aPreviewBeforeTheWorktreeIsKnownHasTheCaptionOnly() throws {
        let item = SwitcherItem(id: "worktree:x", kind: .worktree, title: "x", plotName: "Widgets", target: .worktree("x"))
        let context = SwitcherPreview.Context(plots: [:], panes: [], changes: [], checkouts: [:], actorText: { _ in "" },
                                              clock: { _ in "" }, home: "")
        let preview = SwitcherPreview.make(for: item, in: context)
        #expect(preview.caption == "Worktree" && preview.rows.map(\.label) == ["Plot"])
    }
}
