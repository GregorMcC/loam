import Foundation
import Testing

@testable import LoamKit

@Suite struct SidebarModelTests {
    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-10-02T00:00:00Z")
    }

    func spec(_ plot: String, _ title: String = "shell") -> PaneSpec {
        PaneSpec(kind: .shell, plot: plot, title: title)
    }

    var plots: [PlotSummary] { [plot("a", "Alpha"), plot("b", "Beta"), plot("c", "Gamma")] }

    @Test func plotsWithPanesComeFirstInStoredOrderAndOthersGoToNoPanes() {
        var ws = Workspace()
        ws.openTab(spec("c"))
        ws.openTab(spec("a"))
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false)
        #expect(model.withPanes.map(\.id) == ["a", "c"])
        #expect(model.noPanes.map(\.id) == ["b"])
    }

    @Test func shortcutNumbersFollowTheStoredOrder() {
        var ws = Workspace()
        ws.openTab(spec("c"))
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false)
        #expect(model.withPanes.first?.number == 3)
        #expect(model.noPanes.map(\.number) == [1, 2])
    }

    @Test func onlyTheFirstNinePlotsGetANumber() {
        let many = (1...11).map { plot("p\($0)", "Plot \($0)") }
        let model = SidebarModel(plots: many, workspace: Workspace(), collapsed: false)
        #expect(model.noPanes.last?.number == nil)
        #expect(model.noPanes[8].number == 9)
        #expect(model.plotID(forNumber: 10) == nil)
        #expect(model.plotID(forNumber: 0) == nil)
    }

    @Test func plotIDForNumberUsesStoredOrder() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false)
        #expect(model.plotID(forNumber: 1) == "a")
        #expect(model.plotID(forNumber: 3) == "c")
        #expect(model.plotID(forNumber: 4) == nil)
    }

    @Test func onlyTheActivePlotListsItsPanes() {
        var ws = Workspace()
        let a1 = ws.openTab(spec("a", "claude-1"))
        ws.split(plot: "a", axis: .sideBySide, spec("a", "shell"))
        ws.openTab(spec("b"))
        ws.activate(plot: "a")
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false)
        #expect(model.activePanes.map(\.title) == ["claude-1", "shell"])
        #expect(model.activePanes.first?.id == a1)
        let rowB = model.withPanes.first { $0.id == "b" }
        #expect(rowB?.paneCount == 1)
        #expect(rowB?.isActive == false)
        #expect(model.withPanes.first { $0.id == "a" }?.isActive == true)
    }

    @Test func paneRowShowsTheStateAndFocus() {
        var ws = Workspace()
        let p = ws.openTab(spec("a"))
        let q = ws.split(plot: "a", axis: .stacked, spec("a"))!
        ws.setState(.ended, of: p)
        ws.activate(plot: "a")
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false)
        #expect(model.activePanes.map(\.state) == [.ended, .running])
        #expect(model.activePanes.map(\.isFocused) == [false, true])
        #expect(model.activePanes.last?.id == q)
    }

    /// Ticket 68: the toolbar shows the title, so it names the plot also while the sidebar shows.
    @Test func titleShowsThePlotName() {
        var ws = Workspace()
        ws.activate(plot: "b")
        #expect(SidebarModel(plots: plots, workspace: ws, collapsed: true).windowTitle == "Beta")
        #expect(SidebarModel(plots: plots, workspace: ws, collapsed: false).windowTitle == "Beta")
        #expect(SidebarModel(plots: plots, workspace: Workspace(), collapsed: true).windowTitle == "Loam")
    }

    @Test func dropPositionMovesDownToTheTargetSlot() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false)
        // Dragging Alpha onto Gamma puts Alpha last: position 3.
        #expect(model.dropPosition(moving: "a", onto: "c") == 3)
        #expect(model.dropPosition(moving: "c", onto: "a") == 1)
        #expect(model.dropPosition(moving: "b", onto: "a") == 1)
    }

    @Test func dropOnItselfOrAnUnknownPlotGivesNil() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false)
        #expect(model.dropPosition(moving: "a", onto: "a") == nil)
        #expect(model.dropPosition(moving: "a", onto: "zzz") == nil)
        #expect(model.dropPosition(moving: "zzz", onto: "a") == nil)
    }

    @Test func nextAndPreviousPlotWrapInStoredOrder() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false)
        #expect(model.plotID(after: "c") == "a")
        #expect(model.plotID(before: "a") == "c")
    }

    // MARK: Attention (ticket 32)

    func seeded(_ plot: String, _ id: String) -> PaneSpec {
        PaneSpec(kind: .session, plot: plot, title: "claude \(id)", sessionID: id)
    }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/tmp", at: "2026-10-03T09:00:00Z", source: nil, notificationType: nil)
    }

    /// Plot a: panes a1 and a2 (a2 focused). Plot b: b1 and b2 in 2 tabs. Plot c: c1. a is active.
    func attentionSample() -> (ws: Workspace, a1: PaneID, a2: PaneID, b1: PaneID, b2: PaneID, c1: PaneID) {
        var ws = Workspace()
        let c1 = ws.openTab(seeded("c", "c1"))
        let b1 = ws.openTab(seeded("b", "b1"))
        let b2 = ws.openTab(seeded("b", "b2"))
        let a1 = ws.openTab(seeded("a", "a1"))
        let a2 = ws.split(plot: "a", axis: .sideBySide, seeded("a", "a2"))!
        ws.activate(plot: "a")
        return (ws, a1, a2, b1, b2, c1)
    }

    @Test func aPlotRowCountsItsPanesThatNeedYouAndShowsDoneUnreadOtherwise() {
        var s = attentionSample()
        s.ws.apply(event("PermissionRequest", "b1"), to: s.b1)
        s.ws.apply(event("StopFailure", "b2"), to: s.b2)
        s.ws.apply(event("Stop", "c1"), to: s.c1)
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, arriving: [s.b2])
        let rows = Dictionary(uniqueKeysWithValues: model.withPanes.map { ($0.id, $0) })
        #expect(rows["b"]?.needsYouCount == 2 && rows["b"]?.isArriving == true)
        #expect(rows["c"]?.needsYouCount == 0 && rows["c"]?.hasDoneUnread == true && rows["c"]?.isArriving == false)
        #expect(rows["a"]?.needsYouCount == 0 && rows["a"]?.hasDoneUnread == false)
        // Needs you wins: a plot with both shows the count only.
        s.ws.apply(event("Stop", "b1"), to: s.b1)
        let after = SidebarModel(plots: plots, workspace: s.ws, collapsed: false)
        #expect(after.withPanes.first { $0.id == "b" }?.needsYouCount == 1)
    }

    @Test func thePaneRowsOfTheActivePlotCarryTheirMark() {
        var s = attentionSample()
        s.ws.apply(event("PermissionRequest", "a1"), to: s.a1)
        s.ws.apply(event("Stop", "a2"), to: s.a2)
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, arriving: [s.a1])
        #expect(model.activePanes.map(\.attention) == [.needsYou, .doneUnread])
        #expect(model.activePanes.map(\.isArriving) == [true, false])
    }

    @Test func theNeedsYouListShowsOnlyWhileAPaneNeedsYouInSidebarOrder() {
        var s = attentionSample()
        #expect(SidebarModel(plots: plots, workspace: s.ws, collapsed: false).needsYou.isEmpty)
        s.ws.apply(event("PermissionRequest", "c1"), to: s.c1)
        s.ws.apply(event("PermissionRequest", "b2"), to: s.b2)
        s.ws.apply(event("PermissionRequest", "a2"), to: s.a2)
        s.ws.apply(event("Stop", "b1"), to: s.b1)
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: true, arriving: [s.c1])
        #expect(model.needsYou.map(\.id) == [s.a2, s.b2, s.c1])
        #expect(model.needsYou.map(\.plotName) == ["Alpha", "Beta", "Gamma"])
        #expect(model.needsYou.map(\.isFocused) == [true, false, false])
        #expect(model.needsYou.map(\.isArriving) == [false, false, true])
        #expect(model.elsewhereNeedYou == 2)
    }

    @Test func theAttentionRowsCountThePanesInEachStateAcrossPlots() {
        var s = attentionSample()
        let none = SidebarModel(plots: plots, workspace: s.ws, collapsed: false)
        #expect(none.needsYouCount == 0 && none.doneUnreadCount == 0)
        s.ws.apply(event("PermissionRequest", "c1"), to: s.c1)
        s.ws.apply(event("PermissionRequest", "b2"), to: s.b2)
        s.ws.apply(event("Stop", "b1"), to: s.b1)
        s.ws.apply(event("Stop", "a1"), to: s.a1)
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false)
        #expect(model.needsYouCount == 2)
        #expect(model.doneUnreadCount == 2)
        #expect(model.doneUnread == [s.a1, s.b1])
    }
}

/// Ticket 86: the fixed attention rows count panes and pick the next pane in a state.
struct AttentionCycleTests {
    @Test func theNextPaneFollowsTheFocusedOneAndWrapsRoundToTheStart() {
        let order = (0..<5).map { _ in PaneID() }
        let waiting: Set<PaneID> = [order[1], order[3]]
        #expect(AttentionCycle.next(order: order, matching: waiting, after: order[0]) == order[1])
        #expect(AttentionCycle.next(order: order, matching: waiting, after: order[1]) == order[3])
        #expect(AttentionCycle.next(order: order, matching: waiting, after: order[3]) == order[1])
        #expect(AttentionCycle.next(order: order, matching: waiting, after: order[4]) == order[1])
    }

    @Test func withNoFocusedPaneTheFirstMatchingPaneComesFirst() {
        let order = (0..<3).map { _ in PaneID() }
        #expect(AttentionCycle.next(order: order, matching: [order[2]], after: nil) == order[2])
        #expect(AttentionCycle.next(order: order, matching: [order[2], order[1]], after: PaneID()) == order[1])
    }

    @Test func aCountOfZeroGivesNoPane() {
        let order = (0..<3).map { _ in PaneID() }
        #expect(AttentionCycle.next(order: order, matching: [], after: order[0]) == nil)
    }

    @Test func theOnlyMatchingPaneIsItselfWhenItHasFocus() {
        let order = (0..<3).map { _ in PaneID() }
        #expect(AttentionCycle.next(order: order, matching: [order[1]], after: order[1]) == order[1])
    }
}

/// Ticket 71: the sidebar tree. A plot holds its main checkout and its worktrees, and each holds its panes.
@Suite struct SidebarTreeTests {
    func plot(_ id: String, _ name: String) -> PlotSummary {
        PlotSummary(id: id, name: name, what: "", createdAt: "2026-10-02T00:00:00Z")
    }

    var plots: [PlotSummary] { [plot("a", "Alpha"), plot("b", "Beta")] }

    func ref(_ id: String, _ branch: String) -> WorktreeRef {
        WorktreeRef(id: id, name: branch, branch: branch, path: "/tmp/wt/\(branch)")
    }

    /// A worktree of `repo`, by default the main repo of `mainRepo(plot, _)`.
    func status(_ id: String, _ plot: String, _ branch: String, changed: Int = 0, repo: String? = nil) -> WorktreeStatus {
        WorktreeStatus(
            worktree: Worktree(id: id, plotID: plot, repo: repo ?? "/tmp/\(plot)/repo", name: branch, branch: branch, base: "",
                               path: "/tmp/wt/\(branch)", setupDone: true, createdAt: "2026-10-02T00:00:00Z"),
            missing: false, changed: changed, unpushed: 0, merged: false, mergedInto: nil, error: nil)
    }

    func session(_ plot: String, _ worktree: WorktreeRef? = nil) -> PaneSpec {
        PaneSpec(kind: .session, plot: plot, title: "claude", worktree: worktree)
    }

    func shell(_ plot: String, _ worktree: WorktreeRef? = nil) -> PaneSpec {
        PaneSpec(kind: .shell, plot: plot, title: "shell", worktree: worktree)
    }

    /// The plot's main repo, `/tmp/<plot>/repo`, on `branch`.
    func mainRepo(_ plot: String, _ branch: String) -> [String: [RepoCheckout]] {
        [plot: [RepoCheckout(id: "r-\(plot)", path: "/tmp/\(plot)/repo", isMain: true, branch: branch)]]
    }

    /// Plot a has a main repo on main and 2 worktrees. Panes: a shell in the main checkout, a session
    /// in fix-login, a session in the main checkout (split), a shell in fix-login. Plot b has a session.
    func sample() -> (ws: Workspace, main1: PaneID, fix1: PaneID, main2: PaneID, fix2: PaneID, b1: PaneID,
                      worktrees: [String: [WorktreeStatus]]) {
        var ws = Workspace()
        let fix = ref("wt-fix", "fix-login")
        let b1 = ws.openTab(session("b"))
        let main1 = ws.openTab(shell("a"))
        let fix1 = ws.openTab(session("a", fix))
        let main2 = ws.openTab(session("a"))
        let fix2 = ws.split(plot: "a", axis: .stacked, shell("a", fix))!
        ws.activate(plot: "a")
        let worktrees = ["a": [status("wt-fix", "a", "fix-login"), status("wt-docs", "a", "docs-pass")]]
        return (ws, main1, fix1, main2, fix2, b1, worktrees)
    }

    /// Ticket 92: the worktrees of a repo nest under its row, after the panes of the normal checkout.
    @Test func thePanesGroupUnderTheMainCheckoutAndTheirWorktree() {
        let s = sample()
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, worktrees: s.worktrees,
                                 repos: mainRepo("a", "main"))
        let tree = model.tree(of: "a")
        #expect(tree.panes.isEmpty)
        #expect(tree.checkouts.map(\.id) == ["main-a"])
        let main = tree.checkouts[0]
        #expect(main.kind == .main && main.label == "main")
        #expect(main.worktrees.map(\.kind) == [.worktree, .worktree])
        #expect(main.worktrees.map(\.label) == ["fix-login", "docs-pass"])
        #expect(main.worktrees.map(\.id) == ["wt-fix", "wt-docs"])
        #expect(tree.allCheckouts.map(\.id) == ["main-a", "wt-fix", "wt-docs"])
        // Tab order, then layout order, in each checkout.
        #expect(main.panes.map(\.id) == [s.main1, s.main2])
        #expect(main.worktrees[0].panes.map(\.id) == [s.fix1, s.fix2])
        #expect(main.worktrees[1].panes.isEmpty)
        #expect(main.worktrees[0].worktree?.paneCount == 2)
        #expect(model.checkout(holding: s.fix2)?.id == "wt-fix")
        #expect(model.checkout(holding: s.main1)?.id == "main-a")
    }

    @Test func aPlotWithNoMainRepoHoldsItsOtherPanesItself() {
        let s = sample()
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, worktrees: s.worktrees)
        let tree = model.tree(of: "a")
        #expect(tree.panes.map(\.id) == [s.main1, s.main2])
        #expect(tree.checkouts.map(\.id) == ["wt-fix", "wt-docs"])
        #expect(model.checkout(holding: s.main1) == nil)
        // Plot b: one pane, no repo, no worktree.
        #expect(model.tree(of: "b").panes.map(\.id) == [s.b1])
        #expect(model.tree(of: "b").checkouts.isEmpty)
    }

    @Test func aPlotWithAMainRepoAndNoPanesStillShowsItsMainCheckout() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false, repos: mainRepo("b", "trunk"))
        #expect(model.tree(of: "b").checkouts.map(\.label) == ["trunk"])
        #expect(model.tree(of: "b").checkouts.first?.panes.isEmpty == true)
        #expect(model.tree(of: "a").isEmpty)
    }

    /// A pane can run in a worktree that the last list does not hold, for example while the list
    /// reloads. It still gets its worktree row, after the listed ones.
    @Test func aWorktreeThatTheListMissesStillHoldsItsPane() {
        var ws = Workspace()
        let pane = ws.openTab(session("a", ref("wt-new", "spike")))
        ws.activate(plot: "a")
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false,
                                 worktrees: ["a": [status("wt-fix", "a", "fix-login")]], repos: mainRepo("a", "main"))
        let tree = model.tree(of: "a")
        // The pane's reference has no repo, so the worktree nests under the main repo.
        #expect(tree.checkouts.map(\.id) == ["main-a"])
        let nested = tree.checkouts[0].worktrees
        #expect(nested.map(\.id) == ["wt-fix", "wt-new"])
        #expect(nested[1].label == "spike" && nested[1].panes.map(\.id) == [pane])
        #expect(nested[1].worktree?.paneCount == 1)
        #expect(model.checkout(holding: pane)?.id == "wt-new")
    }

    /// Every plot has its tree, so a plot you open shows its panes. The rows carry the marks and the focus.
    @Test func everyPlotHasItsTreeWithMarksAndFocus() {
        var ws = Workspace()
        let b1 = ws.openTab(PaneSpec(kind: .session, plot: "b", title: "claude", sessionID: "b1"))
        let a1 = ws.openTab(session("a"))
        ws.activate(plot: "a")
        ws.apply(PaneEvent(event: "PermissionRequest", sessionID: "b1", cwd: "/tmp", at: "2026-10-03T09:00:00Z",
                           source: nil, notificationType: nil), to: b1)
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, arriving: [b1])
        #expect(model.tree(of: "b").panes.map(\.attention) == [.needsYou])
        #expect(model.tree(of: "b").panes.map(\.isArriving) == [true])
        #expect(model.tree(of: "b").panes.map(\.isFocused) == [false])
        #expect(model.tree(of: "a").panes.map(\.id) == [a1])
        #expect(model.tree(of: "a").panes.map(\.isFocused) == [true])
    }

    @Test func aPaneRowShowsTheTerminalTitleElseItsOwnTitle() {
        let s = sample()
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, worktrees: s.worktrees,
                                 repos: mainRepo("a", "main"), titles: [s.fix1: "Fix the login form", s.main1: ""])
        #expect(model.tree(of: "a").checkouts[0].panes.map(\.title) == ["shell", "claude"])
        #expect(model.tree(of: "a").checkouts[0].worktrees[0].panes.map(\.title) == ["Fix the login form", "shell"])
        #expect(model.activePanes.first { $0.id == s.fix1 }?.title == "Fix the login form")
    }

    /// A tab of 2 or more panes in one checkout gets its own row, titled by the focused pane. A tab
    /// of one pane stays a plain pane row.
    @Test func aSplitTabGroupsItsPanesUnderATabRow() {
        var ws = Workspace()
        let one = ws.openTab(shell("a"))
        let left = ws.openTab(session("a"))
        let right = ws.split(plot: "a", axis: .sideBySide, shell("a"))!
        ws.activate(plot: "a")
        ws.focus(left)
        let split = ws.tabs(of: "a")[1].id
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, repos: mainRepo("a", "main"),
                                 titles: [left: "Fix the login form"])
        let main = model.tree(of: "a").checkouts[0]
        #expect(main.items.map(\.id) == [.pane(one), .tab(split)])
        guard case .tab(let tab) = main.items[1] else { Issue.record("no tab row"); return }
        #expect(tab.panes.map(\.id) == [left, right])
        #expect(tab.lead == left && tab.title == "Fix the login form")
        #expect(tab.holdsFocus)
        #expect(main.panes.map(\.id) == [one, left, right])
        #expect(model.tab(holding: right)?.id == split)
        #expect(model.tab(holding: one) == nil)
        #expect(model.checkout(holding: right)?.id == "main-a")
        // A plot with no main repo groups the same way.
        let bare = SidebarModel(plots: plots, workspace: ws, collapsed: false).tree(of: "a")
        #expect(bare.items.map(\.id) == [.pane(one), .tab(split)])
    }

    /// A tab whose panes run in different checkouts groups only inside each checkout. A pane alone
    /// in its checkout stays a plain pane row.
    @Test func aTabAcrossCheckoutsGroupsInsideEachCheckout() {
        let s = sample()
        let model = SidebarModel(plots: plots, workspace: s.ws, collapsed: false, worktrees: s.worktrees,
                                 repos: mainRepo("a", "main"))
        let tree = model.tree(of: "a")
        #expect(tree.checkouts[0].items.map(\.id) == [.pane(s.main1), .pane(s.main2)])
        #expect(tree.checkouts[0].worktrees[0].items.map(\.id) == [.pane(s.fix1), .pane(s.fix2)])
        #expect(model.tab(holding: s.fix2) == nil)
    }

    /// The tab row shows the strongest mark of its panes: needs you, then done, unread.
    @Test func aTabRowShowsTheStrongestMarkOfItsPanes() {
        var ws = Workspace()
        let left = ws.openTab(PaneSpec(kind: .session, plot: "a", title: "claude", sessionID: "s1"))
        let right = ws.split(plot: "a", axis: .sideBySide, PaneSpec(kind: .session, plot: "a", title: "claude", sessionID: "s2"))!
        ws.activate(plot: "a")
        ws.apply(PaneEvent(event: "PermissionRequest", sessionID: "s2", cwd: "/tmp", at: "2026-10-03T09:00:00Z",
                           source: nil, notificationType: nil), to: right)
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, arriving: [right])
        guard case .tab(let tab) = model.tree(of: "a").items.first else { Issue.record("no tab row"); return }
        #expect(tab.panes.map(\.id) == [left, right])
        #expect(tab.attention == .needsYou)
        #expect(tab.isArriving)
    }

    /// Ticket 76: every repo of the plot has a row, the main repo first. A session in another repo
    /// sits under that repo's row. With more than one repo, a row shows its folder and its branch.
    @Test func eachRepoOfThePlotHasARowThatHoldsItsPanes() {
        var ws = Workspace()
        let mainPane = ws.openTab(session("a"))
        var webSpec = session("a")
        webSpec.repo = "/tmp/a/web/"
        let webPane = ws.openTab(webSpec)
        ws.activate(plot: "a")
        let repos = ["a": [RepoCheckout(id: "r-main", path: "/tmp/a/loam", isMain: true, branch: "main"),
                           RepoCheckout(id: "r-web", path: "/tmp/a/web", isMain: false, branch: "develop"),
                           RepoCheckout(id: "r-docs", path: "/tmp/a/docs", isMain: false)]]
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, repos: repos)
        let tree = model.tree(of: "a")
        #expect(tree.checkouts.map(\.id) == ["main-a", "repo-r-web", "repo-r-docs"])
        #expect(tree.checkouts.map(\.kind) == [.main, .repo, .repo])
        #expect(tree.checkouts.map(\.label) == ["loam", "web", "docs"])
        #expect(tree.checkouts.map(\.detail) == ["main", "develop", nil])
        #expect(tree.checkouts.map { $0.repo?.path } == ["/tmp/a/loam", "/tmp/a/web", "/tmp/a/docs"])
        #expect(tree.checkouts[0].panes.map(\.id) == [mainPane])
        #expect(tree.checkouts[1].panes.map(\.id) == [webPane])
        #expect(tree.checkouts[2].panes.isEmpty)
        #expect(model.checkout(holding: webPane)?.id == "repo-r-web")
    }

    /// Ticket 92: a worktree nests under the row of its own repo. A worktree of a repo that has no row
    /// stays right under the plot, after the repos.
    @Test func aWorktreeNestsUnderItsOwnRepo() {
        var ws = Workspace()
        var webRef = ref("wt-web", "web-fix")
        webRef.repo = "/tmp/a/web/"
        let pane = ws.openTab(session("a", webRef))
        ws.activate(plot: "a")
        let repos = ["a": [RepoCheckout(id: "r-main", path: "/tmp/a/loam", isMain: true, branch: "main"),
                           RepoCheckout(id: "r-web", path: "/tmp/a/web", isMain: false, branch: "develop")]]
        let worktrees = ["a": [status("wt-main", "a", "spike", repo: "/tmp/a/loam"),
                               status("wt-gone", "a", "old", repo: "/tmp/a/removed")]]
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, worktrees: worktrees, repos: repos)
        let tree = model.tree(of: "a")
        #expect(tree.checkouts.map(\.id) == ["main-a", "repo-r-web", "wt-gone"])
        #expect(tree.checkouts[0].worktrees.map(\.id) == ["wt-main"])
        #expect(tree.checkouts[1].worktrees.map(\.id) == ["wt-web"])
        #expect(tree.checkouts[1].worktrees[0].panes.map(\.id) == [pane])
        #expect(tree.checkouts[1].panes.isEmpty)
        #expect(model.checkout(holding: pane)?.id == "wt-web")
    }

    /// Ticket 93: a plot session sits right under the plot, before the repo rows, also when the plot
    /// has a main repo.
    @Test func aPlotSessionSitsRightUnderThePlot() {
        var ws = Workspace()
        var spec = session("a")
        spec.inPlotFolder = true
        let planning = ws.openTab(spec)
        let code = ws.openTab(session("a"))
        ws.activate(plot: "a")
        let model = SidebarModel(plots: plots, workspace: ws, collapsed: false, repos: mainRepo("a", "main"))
        let tree = model.tree(of: "a")
        #expect(tree.panes.map(\.id) == [planning])
        #expect(tree.checkouts.map(\.id) == ["main-a"])
        #expect(tree.checkouts[0].panes.map(\.id) == [code])
        #expect(model.checkout(holding: planning) == nil)
    }

    /// A plot with one repo keeps the branch as the row label, with no detail.
    @Test func aPlotWithOneRepoShowsTheBranchOnly() {
        let model = SidebarModel(plots: plots, workspace: Workspace(), collapsed: false, repos: mainRepo("b", "trunk"))
        #expect(model.tree(of: "b").checkouts.map(\.label) == ["trunk"])
        #expect(model.tree(of: "b").checkouts.map(\.detail) == [nil])
    }

    /// The selected row is where you are: the focused pane of the active plot, else the active plot.
    @Test func theSelectionIsTheFocusedPaneElseTheActivePlot() {
        var s = sample()
        s.ws.focus(s.fix2)
        #expect(SidebarModel(plots: plots, workspace: s.ws, collapsed: false).selection == .pane(s.fix2))
        var empty = Workspace()
        empty.activate(plot: "b")
        #expect(SidebarModel(plots: plots, workspace: empty, collapsed: false).selection == .plot("b"))
        #expect(SidebarModel(plots: plots, workspace: Workspace(), collapsed: false).selection == nil)
    }
}

/// Ticket 71: which plots of the tree are open. By default only the active plot shows its panes (spec 8.1).
@Suite struct SidebarDisclosureTests {
    @Test func theActivePlotOpensAndClosesWhenYouLeaveIt() {
        var disclosure = SidebarDisclosure()
        disclosure.activePlotChanged(to: "a")
        #expect(disclosure.isOpen(plot: "a"))
        disclosure.activePlotChanged(to: "b")
        #expect(!disclosure.isOpen(plot: "a") && disclosure.isOpen(plot: "b"))
        disclosure.activePlotChanged(to: nil)
        #expect(disclosure.openPlots.isEmpty)
    }

    @Test func aPlotYouOpenStaysOpen() {
        var disclosure = SidebarDisclosure()
        disclosure.activePlotChanged(to: "a")
        disclosure.setPlot("c", open: true)
        disclosure.activePlotChanged(to: "c")
        disclosure.activePlotChanged(to: "b")
        #expect(disclosure.openPlots == ["b", "c"])
    }

    @Test func theActivePlotThatYouCloseStaysClosedUntilYouComeBack() {
        var disclosure = SidebarDisclosure()
        disclosure.activePlotChanged(to: "a")
        disclosure.setPlot("a", open: false)
        disclosure.activePlotChanged(to: "a")
        #expect(!disclosure.isOpen(plot: "a"))
        disclosure.activePlotChanged(to: "b")
        disclosure.activePlotChanged(to: "a")
        #expect(disclosure.isOpen(plot: "a") && !disclosure.isOpen(plot: "b"))
    }

    /// Opening the active plot again by hand makes it yours, so it stays open when you leave.
    @Test func reopeningTheActivePlotByHandKeepsItOpen() {
        var disclosure = SidebarDisclosure()
        disclosure.activePlotChanged(to: "a")
        disclosure.setPlot("a", open: false)
        disclosure.setPlot("a", open: true)
        disclosure.activePlotChanged(to: "b")
        #expect(disclosure.openPlots == ["a", "b"])
    }

    @Test func aCheckoutIsOpenUntilYouCloseIt() {
        var disclosure = SidebarDisclosure()
        #expect(disclosure.isOpen(checkout: "wt-fix"))
        disclosure.setCheckout("wt-fix", open: false)
        #expect(!disclosure.isOpen(checkout: "wt-fix"))
        disclosure.setCheckout("wt-fix", open: true)
        #expect(disclosure.isOpen(checkout: "wt-fix"))
    }

    @Test func aTabIsOpenUntilYouCloseIt() {
        var disclosure = SidebarDisclosure()
        let tab = UUID()
        #expect(disclosure.isOpen(tab: tab))
        disclosure.setTab(tab, open: false)
        #expect(!disclosure.isOpen(tab: tab))
        disclosure.setTab(tab, open: true)
        #expect(disclosure.isOpen(tab: tab))
    }
}

@Suite struct TabBarAttentionTests {
    func seeded(_ id: String) -> PaneSpec { PaneSpec(kind: .session, plot: "p", title: id, sessionID: id) }

    func event(_ name: String, _ id: String) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/tmp", at: "2026-10-03T09:00:00Z", source: nil, notificationType: nil)
    }

    @Test func eachTabShowsTheStrongestMarkOfItsPanes() {
        var ws = Workspace()
        let one = ws.openTab(seeded("one"))
        let two = ws.split(plot: "p", axis: .sideBySide, seeded("two"))!
        let three = ws.openTab(seeded("three"))
        let four = ws.openTab(seeded("four"))
        ws.apply(event("Stop", "one"), to: one)
        ws.apply(event("PermissionRequest", "two"), to: two)
        ws.apply(event("Stop", "three"), to: three)
        ws.focus(two)
        let items = TabBarModel(workspace: ws, plot: "p", arriving: [two]).items
        #expect(items.map(\.attention) == [.needsYou, .doneUnread, .none])
        #expect(items[0].isArriving && items[0].paneFocused)
        #expect(!items[1].isArriving && !items[1].paneFocused)
        _ = four
    }
}
