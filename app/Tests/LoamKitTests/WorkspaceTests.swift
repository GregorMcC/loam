import Foundation
import Testing

@testable import LoamKit

@Suite struct WorkspaceTests {
    func spec(_ plot: String, _ title: String = "shell") -> PaneSpec {
        PaneSpec(kind: .shell, plot: plot, folder: "/tmp", title: title)
    }

    @Test func openTabAddsAPaneAndSelectsTheTab() {
        var ws = Workspace()
        let p1 = ws.openTab(spec("A"))
        let p2 = ws.openTab(spec("A"))
        #expect(ws.tabs(of: "A").count == 2)
        #expect(ws.selectedTab(of: "A")?.focused == p2)
        #expect(ws.selectedTab(of: "A")?.tree == .leaf(p2))
        #expect(ws.paneIDs(of: "A") == [p1, p2])
        #expect(ws.paneCount(of: "A") == 1 + 1)
        #expect(ws.paneCount(of: "B") == 0)
    }

    @Test func tabNumbersSelectTheNthTabAndNineSelectsTheLast() {
        var ws = Workspace()
        let ids = (0..<4).map { _ in ws.openTab(spec("A")) }
        ws.selectTab(number: 2, in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == ids[1])
        ws.selectTab(number: 9, in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == ids[3])
        ws.selectTab(number: 7, in: "A")  // Out of range: no change.
        #expect(ws.selectedTab(of: "A")?.focused == ids[3])
    }

    @Test func aClickOnTabNineOfTwelveSelectsTheNinthTabButTheKeyNineSelectsTheLast() {
        var ws = Workspace()
        let ids = (0..<12).map { _ in ws.openTab(spec("A")) }
        ws.selectTab(index: 8, in: "A")  // The tab bar click: by position.
        #expect(ws.selectedTab(of: "A")?.focused == ids[8])
        ws.selectTab(number: 9, in: "A")  // ⌘9 and goto_tab:9.
        #expect(ws.selectedTab(of: "A")?.focused == ids[11])
        ws.selectTab(index: 0, in: "A")
        ws.selectTab(number: 13, in: "A")  // goto_tab:N above the count does nothing.
        #expect(ws.selectedTab(of: "A")?.focused == ids[0])
        ws.selectTab(index: 12, in: "A")
        ws.selectTab(index: -1, in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == ids[0])
    }

    @Test func nextAndPreviousTabWrap() {
        var ws = Workspace()
        let ids = (0..<3).map { _ in ws.openTab(spec("A")) }
        ws.nextTab(in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == ids[0])
        ws.previousTab(in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == ids[2])
    }

    @Test func splitAddsASecondPaneNextToTheFocusedOne() {
        var ws = Workspace()
        let first = ws.openTab(spec("A"))
        let second = ws.split(plot: "A", axis: .sideBySide, spec("A"))
        #expect(second != nil)
        #expect(ws.selectedTab(of: "A")?.tree.paneIDs == [first, second!])
        #expect(ws.selectedTab(of: "A")?.focused == second)
        #expect(ws.tabs(of: "A").count == 1)
    }

    @Test func splitWithNoTabDoesNothing() {
        var ws = Workspace()
        #expect(ws.split(plot: "A", axis: .stacked, spec("A")) == nil)
    }

    @Test func closingAPaneFocusesItsNeighbour() {
        var ws = Workspace()
        let first = ws.openTab(spec("A"))
        let second = ws.split(plot: "A", axis: .sideBySide, spec("A"))!
        ws.closePane(second)
        #expect(ws.selectedTab(of: "A")?.tree == .leaf(first))
        #expect(ws.selectedTab(of: "A")?.focused == first)
        #expect(ws.spec(of: second) == nil)
    }

    @Test func closingTheLastPaneClosesTheTabAndSelectsANeighbourTab() {
        var ws = Workspace()
        let t1 = ws.openTab(spec("A"))
        let t2 = ws.openTab(spec("A"))
        ws.closePane(t2)
        #expect(ws.tabs(of: "A").count == 1)
        #expect(ws.selectedTab(of: "A")?.focused == t1)
        ws.closePane(t1)
        #expect(ws.tabs(of: "A").isEmpty)
        #expect(ws.paneCount(of: "A") == 0)
    }

    @Test func closingATabBeforeTheSelectedOneKeepsTheSelection() {
        var ws = Workspace()
        let t1 = ws.openTab(spec("A"))
        _ = ws.openTab(spec("A"))
        let t3 = ws.openTab(spec("A"))
        ws.closePane(t1)
        #expect(ws.selectedTab(of: "A")?.focused == t3)
    }

    @Test func plotsKeepSeparateTabsAndSwitchingKeepsPanes() {
        var ws = Workspace()
        let a = ws.openTab(spec("A"))
        let b = ws.openTab(spec("B"))
        ws.activate(plot: "A")
        #expect(ws.activePlotID == "A")
        ws.activate(plot: "B")
        #expect(ws.paneIDs(of: "A") == [a])
        #expect(ws.paneIDs(of: "B") == [b])
        #expect(ws.allPaneIDs.count == 2)
    }

    @Test func removePlotReturnsItsPanes() {
        var ws = Workspace()
        let a1 = ws.openTab(spec("A"))
        let a2 = ws.split(plot: "A", axis: .stacked, spec("A"))!
        let b = ws.openTab(spec("B"))
        ws.activate(plot: "A")
        let removed = ws.removePlot("A")
        #expect(Set(removed) == [a1, a2])
        #expect(ws.allPaneIDs == [b])
        #expect(ws.activePlotID == nil)
    }

    @Test func focusMovesBetweenPanesOfTheSelectedTab() {
        var ws = Workspace()
        let first = ws.openTab(spec("A"))
        let second = ws.split(plot: "A", axis: .sideBySide, spec("A"))!
        ws.focus(first)
        #expect(ws.selectedTab(of: "A")?.focused == first)
        ws.focusNextPane(in: "A")
        #expect(ws.selectedTab(of: "A")?.focused == second)
    }

    @Test func focusingAPaneInAnotherTabSelectsThatTab() {
        var ws = Workspace()
        let t1 = ws.openTab(spec("A"))
        _ = ws.openTab(spec("A"))
        ws.focus(t1)
        #expect(ws.selectedTab(of: "A")?.focused == t1)
    }

    @Test func paneStateStartsRunningAndCanEnd() {
        var ws = Workspace()
        let p = ws.openTab(spec("A"))
        #expect(ws.state(of: p) == .running)
        ws.setState(.ended, of: p)
        #expect(ws.state(of: p) == .ended)
    }

    @Test func roundTripsThroughJSON() throws {
        var ws = Workspace()
        _ = ws.openTab(spec("A"))
        _ = ws.split(plot: "A", axis: .sideBySide, spec("A"))
        ws.activate(plot: "A")
        let data = try JSONEncoder().encode(ws)
        #expect(try JSONDecoder().decode(Workspace.self, from: data) == ws)
    }
}
