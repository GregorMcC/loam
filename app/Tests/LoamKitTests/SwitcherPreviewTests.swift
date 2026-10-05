import Foundation
import Testing
@testable import LoamKit

private func plotDetail(_ id: String, _ name: String, where stands: String = "", links: [PlotLink] = [],
                        repos: [Repo] = []) -> Plot {
    Plot(id: id, name: name, what: "", why: "", whereItStands: stands, createdAt: "2026-01-01T00:00:00Z",
         archived: false, links: links, repos: repos, versions: [:], revision: 1)
}

private func plotLink(_ id: String, _ label: String, _ target: String, _ kind: LinkKind) -> PlotLink {
    PlotLink(id: id, label: label, target: target, note: "", position: 0, version: 1, kind: kind, exists: nil)
}

private func repo(_ id: String, _ path: String, main: Bool = false) -> Repo {
    Repo(id: id, path: path, note: "", main: main, version: 1, setup: nil, copy: nil)
}

private func paneFacts(_ id: String, plot: String = "p1", title: String = "shell", attention: PaneAttention = .none,
                       state: PaneState? = .running, folder: String? = nil, worktree: WorktreeRef? = nil,
                       kind: PaneSpec.Kind? = .shell, saved: Bool = false) -> SwitcherPreview.PaneFacts {
    SwitcherPreview.PaneFacts(id: SwitcherItem.paneKey(id), plotID: plot, title: title, kind: kind, state: state,
                              attention: attention, folder: folder, worktree: worktree, saved: saved)
}

private func change(_ id: Int, plot: String = "p1", item: String = "where") -> Change {
    Change(id: id, plotID: plot, at: "2026-10-04T14:02:00Z", actor: Actor(kind: .session, sessionID: "abc", loamStarted: true),
           entries: [ChangeEntry(item: item, field: "value", old: "a", new: "b")], undoOf: nil)
}

private let plotItem = SwitcherItem(id: "plot:p1", kind: .plot, title: "Loam v1 build", target: .plot("p1"))

private func paneItem(_ id: String, _ title: String) -> SwitcherItem {
    SwitcherItem(id: SwitcherItem.paneKey(id), kind: .pane, title: title, plotName: "Loam v1 build",
                 target: .savedPane(SavedPane(id: id, plotID: "p1", title: title)))
}

private func context(plots: [Plot] = [], panes: [SwitcherPreview.PaneFacts] = [], changes: [Change] = [],
                     checkouts: [String: [RepoCheckout]] = [:]) -> SwitcherPreview.Context {
    SwitcherPreview.Context(
        plots: Dictionary(uniqueKeysWithValues: plots.map { ($0.id, $0) }), panes: panes, changes: changes,
        checkouts: checkouts, actorText: { _ in "Claude" }, clock: { _ in "14:02" }, home: "/Users/me")
}

private func value(_ preview: SwitcherPreview, _ label: String) -> SwitcherPreview.Value? {
    preview.rows.first { $0.label == label }?.value
}

@Suite struct SwitcherPreviewTests {
    @Test func aPlotCaptionCountsPanesAndLinks() {
        let plot = plotDetail("p1", "Loam v1 build", links: [plotLink("l1", "Spec", "/x", .path)])
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plot], panes: [paneFacts("a"), paneFacts("b")]))
        #expect(preview.title == "Loam v1 build")
        #expect(preview.caption == "Plot · 2 panes · 1 link")
        #expect(preview.footerAction == "Open plot")
    }

    @Test func aPlotCaptionBeforeTheDetailsLoadHasNoLinkCount() {
        let preview = SwitcherPreview.make(for: plotItem, in: context(panes: [paneFacts("a")]))
        #expect(preview.caption == "Plot · 1 pane")
        #expect(value(preview, "Main repo") == nil)
    }

    @Test func aPlotShowsWhereItStands() {
        let plot = plotDetail("p1", "Loam v1 build", where: "Built and in use.")
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plot]))
        #expect(preview.whereItStands == "Built and in use.")
    }

    @Test func aPlotShowsMainRepoWithBranchAndAllRepoNames() {
        let plot = plotDetail("p1", "Loam v1 build", repos: [repo("r1", "/dev/loam", main: true), repo("r2", "/dev/recipe-manager")])
        let checkouts = ["p1": [RepoCheckout(id: "r1", path: "/dev/loam", isMain: true, branch: "main"),
                                RepoCheckout(id: "r2", path: "/dev/recipe-manager", isMain: false, branch: "dev")]]
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plot], checkouts: checkouts))
        #expect(value(preview, "Main repo") == .branch(name: "loam", branch: "main"))
        #expect(value(preview, "Repos") == .tags(["loam", "recipe-manager"]))
    }

    @Test func aMainRepoWithoutABranchShowsItsName() {
        let plot = plotDetail("p1", "P", repos: [repo("r1", "/dev/loam", main: true)])
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plot]))
        #expect(value(preview, "Main repo") == .branch(name: "loam", branch: nil))
    }

    @Test func aPlotShowsThePanesThatNeedYouAndTheDoneOnes() {
        let panes = [paneFacts("a", title: "Claude · one", attention: .needsYou),
                     paneFacts("b", title: "Claude · two", attention: .doneUnread),
                     paneFacts("c", title: "Claude · three", attention: .doneUnread),
                     paneFacts("d", plot: "p2", title: "Other", attention: .needsYou)]
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plotDetail("p1", "P")], panes: panes))
        #expect(value(preview, "Panes") == .text("3"))
        #expect(value(preview, "Needs you") == .attention(.needsYou, "Claude · one"))
        #expect(value(preview, "Done, unread") == .attention(.doneUnread, "Claude · two and 1 more"))
    }

    @Test func aPlotWithNoAlertPanesHasNoAlertRows() {
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plotDetail("p1", "P")], panes: [paneFacts("a")]))
        #expect(value(preview, "Needs you") == nil)
        #expect(value(preview, "Done, unread") == nil)
    }

    @Test func aPlotShowsTheLastChangeOfThePlot() {
        let changes = [change(1), change(2), change(3, plot: "p2")]
        let preview = SwitcherPreview.make(for: plotItem, in: context(plots: [plotDetail("p1", "P")], changes: changes))
        #expect(value(preview, "Last change") == .text("Claude: Edited Where it stands, 14:02"))
    }

    @Test func aPaneShowsItsPlotCheckoutStateAndFolder() {
        let worktree = WorktreeRef(id: "w1", name: "ticket-86", branch: "redesign-86", path: "/Users/me/dev/loam-86")
        let facts = paneFacts("a", title: "Claude · ticket 86", state: .working, folder: "/Users/me/dev/loam-86", worktree: worktree)
        let preview = SwitcherPreview.make(for: paneItem("a", "Claude · ticket 86"), in: context(panes: [facts]))
        #expect(preview.caption == "Pane · Shell")
        #expect(value(preview, "Plot") == .text("Loam v1 build"))
        #expect(value(preview, "Checkout") == .branch(name: "ticket-86", branch: "redesign-86"))
        #expect(value(preview, "State") == .text("Working"))
        #expect(value(preview, "Folder") == .path("~/dev/loam-86"))
        #expect(preview.footerAction == "Go to pane")
    }

    @Test func aPaneOutsideAWorktreeTakesTheMainCheckout() {
        let facts = paneFacts("a", folder: "/dev/loam")
        let checkouts = ["p1": [RepoCheckout(id: "r1", path: "/dev/loam", isMain: true, branch: "main")]]
        let preview = SwitcherPreview.make(for: paneItem("a", "shell"), in: context(panes: [facts], checkouts: checkouts))
        #expect(value(preview, "Checkout") == .branch(name: "loam", branch: "main"))
    }

    @Test func aPaneThatNeedsYouSaysSoWithTheMark() {
        let facts = paneFacts("a", attention: .needsYou, state: .needsYou, kind: .session)
        let preview = SwitcherPreview.make(for: paneItem("a", "Claude"), in: context(panes: [facts]))
        #expect(preview.caption == "Pane · Claude session")
        #expect(value(preview, "State") == .attention(.needsYou, "Needs you"))
    }

    @Test func aSavedPaneIsNotResumed() {
        let facts = paneFacts("a", state: nil, kind: nil, saved: true)
        let preview = SwitcherPreview.make(for: paneItem("a", "old"), in: context(panes: [facts]))
        #expect(value(preview, "State") == .text("Not resumed"))
        #expect(preview.footerAction == "Go to pane")
    }

    @Test func aLinkShowsItsKindTargetAndPlot() {
        let item = SwitcherItem(id: "link:p1:l1", kind: .link, title: "Redesign map", plotName: "Loam v1 build",
                                target: .link(plot: "p1", link: "l1"), linkKind: .path, linkTarget: "/Users/me/dev/map.md")
        let preview = SwitcherPreview.make(for: item, in: context())
        #expect(preview.caption == "Local link")
        #expect(value(preview, "Target") == .path("~/dev/map.md"))
        #expect(value(preview, "Plot") == .text("Loam v1 build"))
        #expect(preview.footerAction == "Open link")
    }

    @Test func aWebLinkTargetIsShownAsText() {
        let item = SwitcherItem(id: "l", kind: .link, title: "Repo", plotName: "P", target: .link(plot: "p1", link: "l1"),
                                linkKind: .github, linkTarget: "https://github.com/GregorMcC/loam")
        #expect(value(SwitcherPreview.make(for: item, in: context()), "Target") == .text("https://github.com/GregorMcC/loam"))
    }

    @Test func anActionShowsItsShortcut() {
        let item = SwitcherItem(id: "action:x", kind: .action, title: "Toggle Sidebar", shortcut: "⌘B", target: .action("x"))
        let preview = SwitcherPreview.make(for: item, in: context())
        #expect(preview.caption == "Action")
        #expect(value(preview, "Shortcut") == .keys(["⌘", "B"]))
        #expect(preview.footerAction == "Run")
    }

    @Test func anActionWithoutAShortcutHasNoRow() {
        let item = SwitcherItem(id: "action:x", kind: .action, title: "Do", target: .action("x"))
        #expect(SwitcherPreview.make(for: item, in: context()).rows.isEmpty)
    }

    @Test func rowAccessoryAndSubtitle() {
        let link = SwitcherItem(id: "l", kind: .link, title: "t", plotName: "Plot A", target: .link(plot: "p", link: "l"),
                                linkKind: .github)
        #expect(link.accessory == "GitHub link")
        #expect(paneItem("a", "x").accessory == "Pane")
        #expect(plotItem.accessory == "Plot")
        let ctx = context(panes: [paneFacts("a"), paneFacts("b")])
        #expect(SwitcherPreview.subtitle(for: plotItem, in: ctx) == "2 panes")
        #expect(SwitcherPreview.subtitle(for: link, in: ctx) == "Plot A")
        #expect(SwitcherPreview.subtitle(for: SwitcherItem(id: "a", kind: .action, title: "x", target: .action("a")), in: ctx) == nil)
    }
}
