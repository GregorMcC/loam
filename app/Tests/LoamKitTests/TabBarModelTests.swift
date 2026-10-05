import Foundation
import Testing
@testable import LoamKit

@Suite struct TabBarModelTests {
    private func spec(_ kind: PaneSpec.Kind, _ title: String, command: String? = nil) -> PaneSpec {
        PaneSpec(kind: kind, plot: "p", folder: nil, command: command, env: [:], title: title)
    }

    @Test func noPlotNoTabs() {
        #expect(TabBarModel(workspace: Workspace(), plot: nil).items.isEmpty)
    }

    @Test func listsTabsWithTitleAndSelection() {
        var workspace = Workspace()
        workspace.openTab(spec(.session, "loam"))
        workspace.openTab(spec(.shell, "scratch", command: "/bin/zsh -f"))
        let items = TabBarModel(workspace: workspace, plot: "p").items
        #expect(items.map(\.title) == ["loam", "scratch"])
        #expect(items.map(\.number) == [1, 2])
        #expect(items.map(\.isSelected) == [false, true])
    }

    /// Ticket 71: one label per tab. A seeded session titled "claude" shows "claude" once, not "claude claude".
    @Test func eachTabHasOneLabel() {
        var workspace = Workspace()
        workspace.openTab(spec(.session, "claude"))
        workspace.openTab(spec(.shell, "shell"))
        #expect(TabBarModel(workspace: workspace, plot: "p").items.map(\.title) == ["claude", "shell"])
    }

    /// Ticket 71: the label is the title that the terminal set, else the spec title. A blank title does not count.
    @Test func theTerminalTitleWins() {
        var workspace = Workspace()
        let one = workspace.openTab(spec(.session, "claude"))
        let two = workspace.openTab(spec(.shell, "shell"))
        let titles = [one: "Fix the login form", two: "  "]
        #expect(TabBarModel(workspace: workspace, plot: "p", titles: titles).items.map(\.title) == ["Fix the login form", "shell"])
    }

    /// A split tab shows the title of its focused pane.
    @Test func aSplitTabShowsItsFocusedPane() {
        var workspace = Workspace()
        let left = workspace.openTab(spec(.session, "claude"))
        let right = workspace.split(plot: "p", axis: .sideBySide, spec(.shell, "shell"))!
        #expect(TabBarModel(workspace: workspace, plot: "p", titles: [right: "vim"]).items.map(\.title) == ["vim"])
        workspace.focus(left)
        #expect(TabBarModel(workspace: workspace, plot: "p", titles: [right: "vim"]).items.map(\.title) == ["claude"])
    }

    /// Ticket 88: each pill shows the symbol of its focused pane before the label.
    @Test func eachTabCarriesTheIconOfItsFocusedPane() {
        var workspace = Workspace()
        let left = workspace.openTab(spec(.session, "claude"))
        _ = workspace.split(plot: "p", axis: .sideBySide, spec(.shell, "shell"))
        #expect(TabBarModel(workspace: workspace, plot: "p").items.map(\.icon) == [LoamIcon.shell])
        workspace.focus(left)
        #expect(TabBarModel(workspace: workspace, plot: "p").items.map(\.icon) == [LoamIcon.session])
    }
}

/// Ticket 71: the pane header shows only in a tab of two or more panes.
@Suite struct PaneHeaderRuleTests {
    private func spec(_ plot: String = "p") -> PaneSpec { PaneSpec(kind: .shell, plot: plot) }

    @Test func aTabOfOnePaneHasNoHeader() {
        var workspace = Workspace()
        let alone = workspace.openTab(spec())
        #expect(!workspace.showsHeader(alone))
    }

    @Test func eachPaneOfASplitTabHasAHeader() {
        var workspace = Workspace()
        let left = workspace.openTab(spec())
        let right = workspace.split(plot: "p", axis: .sideBySide, spec())!
        let alone = workspace.openTab(spec())
        #expect(workspace.showsHeader(left) && workspace.showsHeader(right))
        #expect(!workspace.showsHeader(alone))
    }

    @Test func closingTheSplitDropsTheHeader() {
        var workspace = Workspace()
        let left = workspace.openTab(spec())
        let right = workspace.split(plot: "p", axis: .sideBySide, spec())!
        workspace.closePane(right)
        #expect(!workspace.showsHeader(left))
    }

    @Test func anUnknownPaneHasNoHeader() {
        #expect(!Workspace().showsHeader(PaneID()))
    }
}
