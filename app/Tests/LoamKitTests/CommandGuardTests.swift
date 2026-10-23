import Foundation
import Testing

@testable import LoamKit

/// Ticket 128: while a sheet shows or holds the window, a command that acts on the window does nothing, in the menu bar, from
/// a key and from a Ghostty action. The commands of the app stay on. The window asks `commandAllowed` in the menu validation
/// and in `perform(_:)`.
@MainActor
struct CommandGuardTests {
    /// One command of each case that acts on the window.
    static let windowCommands: [AppCommand] = [
        .quickSwitcher, .quickSwitcherActions, .actionsMenu, .nextPaneThatNeedsYou, .nextReadyWorktree, .selectPlot(1),
        .selectHome, .newPlot, .toggleSidebar, .togglePlotPanel, .newShellTab, .newShellSplit(.sideBySide),
        .newTab, .newSplit(.stacked), .focusPane(.next), .selectTab(2), .previousTab, .nextTab, .lastTab, .closePane,
        .closeTab, .equalizeSplits, .resizeSplit(.left, points: 10), .undo, .redo,
        .newHomeSession, .newHomeShell, .moveTabToPlot("p"), .moveTabToNewPlot,
        .newPlotSession, .editBrief, .addLink, .addRepo, .archivePlot,
        .showWorktreePullRequest, .refreshWorktree, .sendFailuresToSession, .landWorktree,
    ]

    /// The commands of the app: Settings, the Ghostty config and Quit.
    static let appCommands: [AppCommand] = [.openSettings, .openConfig, .reloadConfig, .quit]

    func model() -> AppModel {
        let model = AppModel(client: LoamClient())
        model.apply([PlotSummary(id: "p", name: "P", what: "", createdAt: "2026-01-01T00:00:00Z")])
        model.activate(plot: "p")
        return model
    }

    /// Every command of both lists that the model lets run.
    func allowed(_ model: AppModel) -> [AppCommand] {
        (Self.windowCommands + Self.appCommands).filter { model.commandAllowed($0) }
    }

    @Test func everyCommandRunsWithNoSheet() {
        let model = model()
        #expect(!model.sheetIsOpen && !model.sheetHoldsWindow)
        #expect(allowed(model) == Self.windowCommands + Self.appCommands)
    }

    @Test func onlyTheCommandsOfTheAppRunWhileTheLandSheetShows() {
        let model = model()
        model.landSheet.open("wtreeaaaaa")
        #expect(model.sheetIsOpen)
        #expect(allowed(model) == Self.appCommands)
        model.landSheet.close()
        #expect(allowed(model) == Self.windowCommands + Self.appCommands, "the commands run again when the sheet closes")
    }

    @Test func onlyTheCommandsOfTheAppRunWhileTheNewWorktreeSheetShows() {
        let model = model()
        model.newWorktreeSheet.open(plot: "p", link: nil)
        #expect(model.sheetIsOpen)
        #expect(allowed(model) == Self.appCommands)
        model.newWorktreeSheet.close()
        #expect(allowed(model) == Self.windowCommands + Self.appCommands)
    }

    @Test func onlyTheCommandsOfTheAppRunWhileAMergeHoldsTheWindow() {
        let model = model()
        model.landSheet.open("wtreeaaaaa")
        model.landSheet.beginMerging()
        #expect(model.sheetHoldsWindow)
        #expect(allowed(model) == Self.appCommands)
        model.landSheet.endMerging()
        model.landSheet.close()
        #expect(allowed(model) == Self.windowCommands + Self.appCommands)
    }

    @Test func onlyTheCommandsOfTheAppRunWhileAWorktreeStartHoldsTheWindow() {
        let model = model()
        model.newWorktreeSheet.open(plot: "p", link: nil)
        model.newWorktreeSheet.beginStarting()
        #expect(model.sheetHoldsWindow)
        #expect(allowed(model) == Self.appCommands)
        model.newWorktreeSheet.startFailed("The branch is taken.")
        model.newWorktreeSheet.close()
        #expect(allowed(model) == Self.windowCommands + Self.appCommands)
    }

    /// The hold counts with no open sheet too, as it does for the toolbar.
    @Test func aHoldAloneTurnsOffTheCommandsOfTheWindow() {
        let model = model()
        model.landSheet.beginMerging()
        #expect(!model.sheetIsOpen && model.sheetHoldsWindow)
        #expect(allowed(model) == Self.appCommands)
    }

    @Test func theToolbarAndTheCommandsAgree() {
        let model = model()
        for open in [false, true] {
            if open { model.landSheet.open("wtreeaaaaa") }
            #expect(model.toolbarAllows(.newSession) == model.commandAllowed(.newTab))
            #expect(model.toolbarAllows(.toggleSidebar) == model.commandAllowed(.toggleSidebar))
            #expect(model.toolbarAllows(.plotPanel) == model.commandAllowed(.togglePlotPanel))
        }
    }

    @Test func theTwoListsHoldEveryCommandOnce() {
        let all = Self.windowCommands + Self.appCommands
        #expect(Set(all).count == all.count)
        #expect(all.filter(\.actsOnWindow) == Self.windowCommands)
        #expect(all.filter { !$0.actsOnWindow } == Self.appCommands)
    }

    /// The keys that a sheet uses are not commands. A fixed key has a command or a control key, so it takes no Escape, Return
    /// or Tab. No fixed key and no Ghostty default is a text key of a field: ⌘A, ⌘C, ⌘V, ⌘X or ⌘Z.
    @Test func noCommandKeyIsAKeyOfTheSheet() {
        let textKeys = ["a", "c", "v", "x", "z"].map { KeyChord(.command, $0) }
        let chords = LoamKeys.fixed.map(\.chord) + LoamKeys.ghosttyMenuActions.map(\.defaultChord)
        #expect(LoamKeys.fixed.allSatisfy { !$0.chord.mods.isDisjoint(with: [.command, .control]) })
        #expect(chords.allSatisfy { !textKeys.contains($0) })
    }
}
