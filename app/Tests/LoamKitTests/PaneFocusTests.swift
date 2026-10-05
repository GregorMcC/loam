import Foundation
import Testing

@testable import LoamKit

/// Ghostty's `goto_split:<side>` and `close_tab` on the workspace.
@Suite struct PaneFocusTests {
    let a = UUID(), b = UUID(), c = UUID()

    /// a | b over c: a fills the left half, b is top right, c is bottom right.
    var tree: SplitTree {
        SplitTree.leaf(a)
            .splitting(a, axis: .sideBySide, inserting: b)
            .splitting(b, axis: .stacked, inserting: c)
    }

    @Test func findsThePaneOnEachSide() {
        #expect(tree.pane(nextTo: a, toward: .right) == b)  // b and c touch a. The tie goes to layout order.
        #expect(tree.pane(nextTo: b, toward: .left) == a)
        #expect(tree.pane(nextTo: c, toward: .left) == a)
        #expect(tree.pane(nextTo: b, toward: .down) == c)
        #expect(tree.pane(nextTo: c, toward: .up) == b)
    }

    @Test func findsNothingAtTheEdge() {
        #expect(tree.pane(nextTo: a, toward: .left) == nil)
        #expect(tree.pane(nextTo: a, toward: .up) == nil)
        #expect(tree.pane(nextTo: b, toward: .up) == nil)
        #expect(tree.pane(nextTo: c, toward: .right) == nil)
        #expect(SplitTree.leaf(a).pane(nextTo: a, toward: .right) == nil)
    }

    @Test func aPaneMustOverlapAlongTheOtherAxis() {
        // a over b, beside c over d: from b, up is a, and right is d, not c.
        let d = UUID()
        let tree = SplitTree.leaf(a)
            .splitting(a, axis: .sideBySide, inserting: c)
            .splitting(a, axis: .stacked, inserting: b)
            .splitting(c, axis: .stacked, inserting: d)
        #expect(tree.pane(nextTo: b, toward: .up) == a)
        #expect(tree.pane(nextTo: b, toward: .right) == d)
        #expect(tree.pane(nextTo: a, toward: .right) == c)
    }

    @Test func theWorkspaceMovesFocusAndClosesTheSelectedTab() {
        var workspace = Workspace()
        workspace.activate(plot: "p")
        let first = workspace.openTab(PaneSpec(kind: .shell, plot: "p", title: "one"))
        let second = workspace.split(plot: "p", axis: .sideBySide, PaneSpec(kind: .shell, plot: "p", title: "two"))!
        #expect(workspace.selectedTab(of: "p")?.focused == second)
        workspace.focusPane(toward: .left, in: "p")
        #expect(workspace.selectedTab(of: "p")?.focused == first)
        workspace.focusPane(toward: .left, in: "p")
        #expect(workspace.selectedTab(of: "p")?.focused == first)

        let other = workspace.openTab(PaneSpec(kind: .shell, plot: "p", title: "three"))
        workspace.selectTab(number: 1, in: "p")
        workspace.closeSelectedTab(in: "p")
        #expect(workspace.tabs(of: "p").count == 1)
        #expect(workspace.paneIDs(of: "p") == [other])
        #expect(workspace.spec(of: first) == nil && workspace.spec(of: second) == nil)
    }
}
