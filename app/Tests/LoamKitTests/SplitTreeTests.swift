import CoreGraphics
import Foundation
import Testing

@testable import LoamKit

@Suite struct SplitTreeTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test func singleLeafFillsTheRect() {
        let tree = SplitTree.leaf(a)
        #expect(tree.paneIDs == [a])
        #expect(tree.frames(in: CGRect(x: 0, y: 0, width: 100, height: 50)) == [a: CGRect(x: 0, y: 0, width: 100, height: 50)])
    }

    @Test func splittingPutsTheNewPaneSecond() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b)
        #expect(tree.paneIDs == [a, b])
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(frames[b] == CGRect(x: 50, y: 0, width: 50, height: 50))
    }

    @Test func stackedSplitPutsTheFirstPaneOnTop() {
        // AppKit y grows upward, so the first pane gets the upper half.
        let tree = SplitTree.leaf(a).splitting(a, axis: .stacked, inserting: b)
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(frames[a] == CGRect(x: 0, y: 25, width: 100, height: 25))
        #expect(frames[b] == CGRect(x: 0, y: 0, width: 100, height: 25))
    }

    @Test func splittingANestedPaneKeepsTheRest() {
        let tree = SplitTree.leaf(a)
            .splitting(a, axis: .sideBySide, inserting: b)
            .splitting(b, axis: .stacked, inserting: c)
        #expect(tree.paneIDs == [a, b, c])
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 50, height: 100))
        #expect(frames[b] == CGRect(x: 50, y: 50, width: 50, height: 50))
        #expect(frames[c] == CGRect(x: 50, y: 0, width: 50, height: 50))
    }

    @Test func splittingAnUnknownPaneChangesNothing() {
        let tree = SplitTree.leaf(a)
        #expect(tree.splitting(b, axis: .sideBySide, inserting: c) == tree)
    }

    @Test func removingASiblingLetsTheOtherTakeTheSpace() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b)
        #expect(tree.removing(a) == .leaf(b))
        #expect(tree.removing(b) == .leaf(a))
    }

    @Test func removingTheLastPaneGivesNil() {
        #expect(SplitTree.leaf(a).removing(a) == nil)
    }

    @Test func removingAnUnknownPaneChangesNothing() {
        #expect(SplitTree.leaf(a).removing(b) == .leaf(a))
    }

    @Test func gapShrinksTheFramesAndLeavesRoomForADivider() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b)
        let frames = tree.frames(in: CGRect(x: 0, y: 0, width: 101, height: 50), gap: 1)
        #expect(frames[a] == CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(frames[b] == CGRect(x: 51, y: 0, width: 50, height: 50))
    }

    @Test func neighbourPicksTheNextPaneThenWraps() {
        let tree = SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b).splitting(b, axis: .stacked, inserting: c)
        #expect(tree.pane(after: a) == b)
        #expect(tree.pane(after: c) == a)
        #expect(tree.pane(before: a) == c)
    }

    @Test func roundTripsThroughJSON() throws {
        let tree = SplitTree.leaf(a).splitting(a, axis: .sideBySide, inserting: b)
        let data = try JSONEncoder().encode(tree)
        #expect(try JSONDecoder().decode(SplitTree.self, from: data) == tree)
    }
}
