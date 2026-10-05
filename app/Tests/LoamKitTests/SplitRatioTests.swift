import CoreGraphics
import Foundation
import Testing

@testable import LoamKit

@Suite struct SplitRatioTests {
    let a = UUID(), b = UUID(), c = UUID()
    let rect = CGRect(x: 0, y: 0, width: 101, height: 50)

    func ratioOfRoot(_ t: SplitTree) -> Double? {
        if case .split(_, let r, _, _) = t { return r }
        return nil
    }

    func sideBySide() -> SplitTree { SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b) }

    @Test func settingTheRatioMovesTheDivider() {
        let frames = sideBySide().settingRatio(0.25, at: []).frames(in: rect, gap: 1)
        #expect(frames[a]?.width == 25)
        #expect(frames[b]?.width == 75)
    }

    @Test func ratioIsClamped() {
        #expect(ratioOfRoot(sideBySide().settingRatio(0, at: [])) == SplitTree.ratioRange.lowerBound)
        #expect(ratioOfRoot(sideBySide().settingRatio(2, at: [])) == SplitTree.ratioRange.upperBound)
    }

    @Test func pathReachesANestedSplit() {
        let tree = sideBySide().splitting(b, axis: .stacked, inserting: c)
        guard case .split(_, let outer, _, let inner) = tree.settingRatio(0.8, at: [1]) else { Issue.record("shape"); return }
        #expect(outer == 0.5)
        #expect(ratioOfRoot(inner) == 0.8)
    }

    @Test func dividersListEachSplit() {
        let dividers = sideBySide().splitting(b, axis: .stacked, inserting: c).dividers(in: rect, gap: 1)
        #expect(dividers.count == 2)
        #expect(dividers[0].path == [])
        #expect(dividers[0].frame == CGRect(x: 50, y: 0, width: 1, height: 50))
        #expect(dividers[1].path == [1])
        #expect(dividers[1].axis == .stacked)
    }

    @Test func dragRatioFollowsThePointer() {
        let d = sideBySide().dividers(in: rect, gap: 1)[0]
        // Divider centre at x=25.5 gives a first pane 25 wide out of 100.
        #expect(d.ratio(at: CGPoint(x: 25.5, y: 10), minPaneSize: 10) == 0.25)
    }

    @Test func dragRatioHonoursTheMinimumPaneSize() {
        let d = sideBySide().dividers(in: rect, gap: 1)[0]
        #expect(d.ratio(at: CGPoint(x: 1, y: 0), minPaneSize: 20) == 0.2)
        #expect(d.ratio(at: CGPoint(x: 500, y: 0), minPaneSize: 20) == 0.8)
    }

    @Test func aMinimumTooBigForTheAreaGivesHalf() {
        let d = sideBySide().dividers(in: rect, gap: 1)[0]
        #expect(d.ratio(at: CGPoint(x: 10, y: 0), minPaneSize: 80) == 0.5)
    }

    @Test func dragRatioOnAStackedSplitCountsFromTheTop() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .stacked, inserting: b)
        let d = tree.dividers(in: CGRect(x: 0, y: 0, width: 50, height: 101), gap: 1)[0]
        #expect(d.ratio(at: CGPoint(x: 0, y: 75.5), minPaneSize: 10) == 0.25)
    }

    @Test func equalizeWeightsNestedSplitsOfTheSameAxis() {
        let tree = sideBySide().splitting(b, axis: .sideBySide, inserting: c).settingRatio(0.9, at: [])
        let eq = tree.equalized()
        #expect(abs(ratioOfRoot(eq)! - 1.0 / 3.0) < 1e-9)
        guard case .split(_, _, _, let inner) = eq else { return }
        #expect(ratioOfRoot(inner) == 0.5)
    }

    @Test func equalizeTreatsAnotherAxisAsOnePane() {
        let tree = sideBySide().splitting(b, axis: .stacked, inserting: c).settingRatio(0.9, at: [])
        #expect(ratioOfRoot(tree.equalized()) == 0.5)
    }

    @Test func resizeMovesTheDividerNextToThePane() {
        #expect(ratioOfRoot(sideBySide().resizing(a, toward: .right, by: 0.1)) == 0.6)
        #expect(ratioOfRoot(sideBySide().resizing(b, toward: .left, by: 0.1)) == 0.4)
    }

    @Test func resizeWithNoDividerOnThatSideChangesNothing() {
        #expect(sideBySide().resizing(a, toward: .left, by: 0.1) == sideBySide())
        #expect(sideBySide().resizing(a, toward: .down, by: 0.1) == sideBySide())
    }

    @Test func resizeAtTheLimitDoesNotMoveAFartherDivider() {
        // a | (b | c). Pane b, moving left, owns the inner divider only... b is first inside: its right edge is inner.
        let tree = sideBySide().splitting(b, axis: .sideBySide, inserting: c).settingRatio(0.95, at: [1])
        let moved = tree.resizing(b, toward: .right, by: 0.1)
        #expect(moved == tree)
    }

    @Test func resizeIsClamped() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .stacked, inserting: b)
        #expect(ratioOfRoot(tree.resizing(a, toward: .down, by: 5)) == SplitTree.ratioRange.upperBound)
        #expect(ratioOfRoot(tree.resizing(b, toward: .up, by: 5)) == SplitTree.ratioRange.lowerBound)
    }

    @Test func codableRoundTripKeepsTheRatio() throws {
        let tree = sideBySide().settingRatio(0.3, at: [])
        let back = try JSONDecoder().decode(SplitTree.self, from: JSONEncoder().encode(tree))
        #expect(back == tree)
        #expect(ratioOfRoot(back) == 0.3)
    }

    @Test func oldTreeWithNoRatioDecodesAsHalf() throws {
        let json = """
        {"split":{"axis":"sideBySide","first":{"leaf":{"_0":"\(a.uuidString)"}},"second":{"leaf":{"_0":"\(b.uuidString)"}}}}
        """
        let tree = try JSONDecoder().decode(SplitTree.self, from: Data(json.utf8))
        #expect(tree == .split(axis: .sideBySide, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
    }

    @Test func workspaceEqualizeAndResizeActOnTheSelectedTab() {
        var ws = Workspace()
        ws.openTab(PaneSpec(kind: .shell, plot: "p"))
        ws.split(plot: "p", axis: .sideBySide, PaneSpec(kind: .shell, plot: "p"))
        let first = ws.selectedTab(of: "p")!.tree.paneIDs[0]
        ws.resize(plot: "p", pane: first, toward: .right, by: 0.2)
        #expect(ratioOfRoot(ws.selectedTab(of: "p")!.tree) == 0.7)
        ws.setRatio(0.3, at: [], plot: "p")
        #expect(ratioOfRoot(ws.selectedTab(of: "p")!.tree) == 0.3)
        ws.equalize(plot: "p")
        #expect(ratioOfRoot(ws.selectedTab(of: "p")!.tree) == 0.5)
    }
}
