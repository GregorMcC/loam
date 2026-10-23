import Foundation
import Testing

@testable import LoamKit

/// Ticket 126: the scrim of a sheet covers the title bar, so no toolbar item takes a click while a sheet shows or holds the
/// window. A click would open a tab, move the plot or the panel, or change the sidebar under the sheet.
@MainActor
struct ToolbarActionTests {
    /// A model with one active plot, so the plot panel has a plot.
    func model() -> AppModel {
        let model = AppModel(client: LoamClient())
        model.apply([PlotSummary(id: "p", name: "P", what: "", createdAt: "2026-01-01T00:00:00Z")])
        model.activate(plot: "p")
        return model
    }

    func allowed(_ model: AppModel) -> [ToolbarAction] {
        ToolbarAction.allCases.filter { model.toolbarAllows($0) }
    }

    @Test func everyItemActsWithNoSheet() {
        let model = model()
        #expect(!model.sheetIsOpen && !model.sheetHoldsWindow)
        #expect(allowed(model) == ToolbarAction.allCases)
    }

    @Test func noItemActsWhileTheLandSheetShows() {
        let model = model()
        model.landSheet.open("wtreeaaaaa")
        #expect(model.sheetIsOpen)
        #expect(allowed(model).isEmpty)
        model.landSheet.close()
        #expect(allowed(model) == ToolbarAction.allCases, "the items act again when the sheet closes")
    }

    @Test func noItemActsWhileTheNewWorktreeSheetShows() {
        let model = model()
        model.newWorktreeSheet.open(plot: "p", link: nil)
        #expect(model.sheetIsOpen)
        #expect(allowed(model).isEmpty)
        model.newWorktreeSheet.close()
        #expect(allowed(model) == ToolbarAction.allCases)
    }

    @Test func noItemActsWhileAMergeHoldsTheWindow() {
        let model = model()
        model.landSheet.open("wtreeaaaaa")
        model.landSheet.beginMerging()
        #expect(model.sheetHoldsWindow)
        #expect(allowed(model).isEmpty)
        model.landSheet.endMerging()
        model.landSheet.close()
        #expect(allowed(model) == ToolbarAction.allCases)
    }

    @Test func noItemActsWhileAWorktreeStartHoldsTheWindow() {
        let model = model()
        model.newWorktreeSheet.open(plot: "p", link: nil)
        model.newWorktreeSheet.beginStarting()
        #expect(model.sheetHoldsWindow)
        #expect(allowed(model).isEmpty)
        model.newWorktreeSheet.startFailed("The branch is taken.")
        model.newWorktreeSheet.close()
        #expect(allowed(model) == ToolbarAction.allCases)
    }

    /// The hold counts with no open sheet too, so a state that the sheet model allows never lets a click through.
    @Test func aHoldAloneStopsEveryItem() {
        let model = model()
        model.landSheet.beginMerging()
        #expect(!model.sheetIsOpen && model.sheetHoldsWindow)
        #expect(allowed(model).isEmpty)
    }

    @Test func homeHasNoPlotPanel() {
        let model = model()
        model.activateHome()
        #expect(allowed(model) == [.toggleSidebar, .needsYou, .newSession])
        model.activate(plot: "p")
        #expect(model.toolbarAllows(.plotPanel))
    }
}
