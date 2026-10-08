import Foundation
import Testing
@testable import LoamKit

/// Ticket 89: the bottom action bar and the actions menu (⌘J).
@Suite struct ActionMenuTests {
    /// The keys of the menu bar in a fresh app: the fixed Loam keys and Ghostty's defaults.
    private func menuChord(_ command: AppCommand) -> KeyChord? {
        LoamKeys.chord(for: command)
            ?? LoamKeys.ghosttyMenuActions.first { $0.command == command }?.defaultChord
    }

    private func sections(pane: String? = "claude", plot: String? = "Loam v1 build",
                          enabled: (AppCommand) -> Bool = { _ in true }) -> [ActionSection] {
        ActionMenu.sections(paneTitle: pane, plotName: plot, chord: menuChord, isEnabled: enabled)
    }

    @Test func listsThePaneThenThePlot() {
        let all = sections()
        #expect(all.map(\.title) == ["claude", "Loam v1 build"])
        #expect(all[0].items.map(\.title) == ["New session", "Split right", "Split down", "Split right with shell", "Split down with shell", "Close pane"])
        #expect(all[1].items.map(\.title) == ["New session in plot", "Edit brief", "Add link", "Add repo", "Archive plot"])
        #expect(all[0].items.map(\.command) == [.newTab, .newSplit(.sideBySide), .newSplit(.stacked),
                                               .newShellSplit(.sideBySide), .newShellSplit(.stacked), .closePane])
        #expect(all[1].items.map(\.command) == [.newPlotSession, .editBrief, .addLink, .addRepo, .archivePlot])
        #expect(all.flatMap(\.items).allSatisfy { !$0.symbol.isEmpty })
    }

    /// The keycaps are the real keys of the menu bar, one keycap per symbol.
    @Test func theKeycapsComeFromTheMenuCommands() {
        let items = sections().flatMap(\.items)
        #expect(items.first { $0.command == .newTab }?.keys == ["⌘", "T"])
        #expect(items.first { $0.command == .newSplit(.stacked) }?.keys == ["⇧", "⌘", "D"])
        #expect(items.first { $0.command == .archivePlot }?.keys == [])
        #expect(items.first { $0.command == .newShellSplit(.sideBySide) }?.keys == ["⌃", "⌘", "D"])
        #expect(items.first { $0.command == .newShellSplit(.stacked) }?.keys == ["⌃", "⇧", "⌘", "D"])
        // A rebind in the Ghostty config moves the keycap with the menu item.
        let rebound = ActionMenu.sections(paneTitle: "p", plotName: "q", chord: { $0 == .newTab ? KeyChord([.control, .option], "n") : nil },
                                          isEnabled: { _ in true })
        #expect(rebound[0].items[0].keys == ["⌃", "⌥", "N"])
    }

    @Test func keycapsSplitAChord() {
        #expect(ActionMenu.keycaps(KeyChord(.command, "j")) == ["⌘", "J"])
        #expect(ActionMenu.keycaps(KeyChord([.command, .shift], "arrow_up")) == ["⇧", "⌘", "↑"])
        #expect(ActionMenu.keycaps(nil) == [])
    }

    @Test func aDisabledCommandIsNotListed() {
        let all = sections(enabled: { $0 != .closePane && $0 != .addRepo })
        #expect(!all.flatMap(\.items).contains { $0.command == .closePane || $0.command == .addRepo })
    }

    @Test func aSectionWithNothingLeftGoes() {
        let all = sections(enabled: { $0 == .editBrief })
        #expect(all.map(\.title) == ["Loam v1 build"])
    }

    @Test func aPaneAndAPlotWithOneNameKeepTwoSections() {
        let all = sections(pane: "loam", plot: "loam")
        #expect(all.map(\.id) == ["pane", "plot"])
        #expect(ActionMenu.filter(all, query: "e").map(\.id) == ["pane", "plot"])
    }

    @Test func noPaneAndNoPlotNameUseTheirKind() {
        #expect(sections(pane: nil, plot: nil).map(\.title) == ["Pane", "Plot"])
    }

    /// The menu and the list agree on what can run: pane commands need a focused pane, plot
    /// commands need an active plot.
    @Test func availabilityFollowsWhatIsFocused() {
        #expect(ActionMenu.isAvailable(.newTab, hasPlot: true, hasPane: false))
        #expect(!ActionMenu.isAvailable(.newTab, hasPlot: false, hasPane: false))
        #expect(!ActionMenu.isAvailable(.newSplit(.sideBySide), hasPlot: true, hasPane: false))
        #expect(!ActionMenu.isAvailable(.closePane, hasPlot: true, hasPane: false))
        #expect(ActionMenu.isAvailable(.closePane, hasPlot: true, hasPane: true))
        #expect(!ActionMenu.isAvailable(.archivePlot, hasPlot: false, hasPane: false))
        #expect(ActionMenu.isAvailable(.archivePlot, hasPlot: true, hasPane: false))
        #expect(ActionMenu.isAvailable(.toggleSidebar, hasPlot: false, hasPane: false))
    }

    @Test func theFilterMatchesEachWordOfTheTitle() {
        let all = sections()
        #expect(ActionMenu.filter(all, query: "").flatMap(\.items).count == 11)
        #expect(ActionMenu.filter(all, query: "split").flatMap(\.items).map(\.title) == [
            "Split right", "Split down", "Split right with shell", "Split down with shell"])
        #expect(ActionMenu.filter(all, query: "  DOWN sp ").flatMap(\.items).map(\.title) == ["Split down", "Split down with shell"])
        #expect(ActionMenu.filter(all, query: "shell down").flatMap(\.items).map(\.title) == ["Split down with shell"])
        #expect(ActionMenu.filter(all, query: "link").map(\.title) == ["Loam v1 build"])
        #expect(ActionMenu.filter(all, query: "zzz").isEmpty)
    }

    @Test func commandJIsALoamKey() {
        #expect(LoamKeys.chord(for: .actionsMenu) == KeyChord(.command, "j"))
        #expect(LoamKeys.route(KeyChord(.command, "j"), isGhosttyBinding: false) == .loam(.actionsMenu))
    }
}

@MainActor @Suite struct ActionMenuModelTests {
    private func model() -> ActionMenuModel {
        let menu = ActionMenuModel()
        menu.open(ActionMenu.sections(paneTitle: "claude", plotName: "Loam", chord: { LoamKeys.chord(for: $0) },
                                      isEnabled: { _ in true }))
        return menu
    }

    @Test func theFirstRowIsSelected() {
        let menu = model()
        #expect(menu.isOpen)
        #expect(menu.selected?.title == "New session")
    }

    @Test func arrowsMoveAndStopAtTheEnds() {
        let menu = model()
        menu.move(-1)
        #expect(menu.selected?.title == "New session")
        menu.move(1)
        menu.move(1)
        #expect(menu.selected?.title == "Split down")
        for _ in 0..<20 { menu.move(1) }
        #expect(menu.selected?.title == "Archive plot")
    }

    @Test func typingFiltersAndSelectsTheFirstMatch() {
        let menu = model()
        menu.move(3)
        menu.query = "add"
        #expect(menu.visible.flatMap(\.items).map(\.title) == ["Add link", "Add repo"])
        #expect(menu.selected?.title == "Add link")
        menu.move(1)
        #expect(menu.selected?.title == "Add repo")
    }

    @Test func returnRunsTheSelectedRowAndCloses() {
        let menu = model()
        menu.query = "down"
        #expect(menu.runSelected() == .newSplit(.stacked))
        #expect(!menu.isOpen)
        #expect(menu.query.isEmpty)
    }

    @Test func returnWithNoMatchRunsNothing() {
        let menu = model()
        menu.query = "zzz"
        #expect(menu.selected == nil)
        #expect(menu.runSelected() == nil)
        #expect(menu.isOpen)
    }
}

@MainActor @Suite struct ActionBarToastTests {
    private let claude = Actor(kind: .session, sessionID: "abc", loamStarted: true)
    private let you = Actor(kind: .app, sessionID: nil, loamStarted: nil)

    private func change(_ id: Int, plot: String = "p1", _ actor: Actor, item: String = "where") -> Change {
        Change(id: id, plotID: plot, at: "2026-10-04T14:02:00Z", actor: actor,
               entries: [ChangeEntry(item: item, field: "value", old: item.hasPrefix("link:") ? nil : "a", new: "b")], undoOf: nil)
    }

    @Test func theFirstReadShowsNoToast() {
        let bar = ActionBarModel()
        bar.changesArrived([change(1, claude)], activePlot: "p1")
        #expect(bar.toast == nil)
    }

    @Test func aNewChangeOfTheActivePlotShowsAToast() {
        let bar = ActionBarModel()
        bar.changesArrived([change(1, claude)], activePlot: "p1")
        bar.changesArrived([change(1, claude), change(2, claude)], activePlot: "p1")
        #expect(bar.toast == "Claude set Where it stands")
        let id = bar.toastID
        bar.changesArrived([change(1, claude), change(2, claude), change(3, you, item: "link:9")], activePlot: "p1")
        #expect(bar.toast == "You added link")
        #expect(bar.toastID == id + 1)
    }

    @Test func aChangeOfAnotherPlotShowsNoToast() {
        let bar = ActionBarModel()
        bar.changesArrived([], activePlot: "p1")
        bar.changesArrived([change(1, plot: "p2", claude)], activePlot: "p1")
        #expect(bar.toast == nil)
    }

    @Test func theToastClearsOnlyForItsOwnID() {
        let bar = ActionBarModel()
        bar.changesArrived([], activePlot: "p1")
        bar.changesArrived([change(1, claude)], activePlot: "p1")
        let first = bar.toastID
        bar.changesArrived([change(1, claude), change(2, claude, item: "what")], activePlot: "p1")
        bar.clearToast(id: first)
        #expect(bar.toast == "Claude set What")
        bar.clearToast(id: bar.toastID)
        #expect(bar.toast == nil)
    }

    @Test func aPlotSwitchClearsTheToast() {
        let bar = ActionBarModel()
        bar.plotID = "p1"
        bar.changesArrived([], activePlot: "p1")
        bar.changesArrived([change(1, claude)], activePlot: "p1")
        bar.plotID = "p1"
        #expect(bar.toast != nil, "the same plot keeps it")
        bar.plotID = "p2"
        #expect(bar.toast == nil)
    }
}
