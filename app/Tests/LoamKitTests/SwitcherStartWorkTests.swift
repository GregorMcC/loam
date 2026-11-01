import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: ⌘Return on an issue link in the switcher starts work. Return still opens the link. The second action is a
/// field of the item (`SwitcherItem.alternate`), so another kind can add one.
@MainActor
@Suite(.waitLimit, .temporaryFolders) struct SwitcherStartWorkTests {
    let plotID = "plotaaaaab"
    let linear = SwitcherLink(plotID: "plotaaaaab", linkID: "lnkaaaaaaa", label: "ENG-482 Link kinds for Figma",
                              target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma", kind: .linear)
    let issue = SwitcherLink(plotID: "plotaaaaab", linkID: "lnkaaaaaab", label: "#57 Fix the switcher width",
                             target: "https://github.com/example/widgets/issues/57", kind: .github)
    let pull = SwitcherLink(plotID: "plotaaaaab", linkID: "lnkaaaaaac", label: "#58 Switcher width",
                            target: "https://github.com/example/widgets/pull/58", kind: .github)
    let notion = SwitcherLink(plotID: "plotaaaaab", linkID: "lnkaaaaaad", label: "Figma plan",
                              target: "https://notion.so/Figma-plan-0123456789abcdef", kind: .notion)
    let web = SwitcherLink(plotID: "plotaaaaab", linkID: "lnkaaaaaae", label: "Figma board", target: "https://example.com/board",
                           kind: .url)

    func items(_ links: [SwitcherLink]) -> [SwitcherItem] {
        let app = AppModel(client: LoamClient(), stateFile: AppStateFile(
            url: temporaryFolder("switcher").appendingPathComponent("state.json")))
        app.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return SwitcherModel.items(plots: app.plots, workspace: app.workspace, terminalTitles: [:], attention: { _ in .none },
                                   savedPanes: [], links: links, actions: [])
    }

    @Test func onlyAnIssueLinkHasStartWork() {
        let items = items([linear, issue, pull, notion, web])
        let alternates = items.filter { $0.kind == .link }.map { ($0.title, $0.alternate?.title) }
        #expect(alternates.map(\.0) == [linear.label, issue.label, pull.label, notion.label, web.label])
        #expect(alternates.map(\.1) == ["Start work\u{2026}", "Start work\u{2026}", nil, nil, nil])
        // The item of a plot has none either.
        #expect(items.filter { $0.kind != .link }.allSatisfy { $0.alternate == nil })
        #expect(items.first { $0.title == linear.label }?.alternate?.action == .startWork(linear))
    }

    @Test func theFooterListsStartWorkBesideTheFirstAction() {
        let items = items([linear, pull])
        let context = SwitcherPreview.Context(plots: [:], panes: [], changes: [], checkouts: [:], actorText: { _ in "" },
                                              clock: { _ in "" }, home: "/Users/me")
        let issue = SwitcherPreview.make(for: items.first { $0.title == linear.label }!, in: context)
        #expect(issue.footerAction == "Open link" && issue.alternateAction == "Start work\u{2026}")
        let request = SwitcherPreview.make(for: items.first { $0.title == pull.label }!, in: context)
        #expect(request.footerAction == "Open link" && request.alternateAction == nil)
    }

    // MARK: The keys

    final class Rig {
        let dir: URL
        let app: AppModel
        init(dir: URL, app: AppModel) {
            self.dir = dir
            self.app = app
        }

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    func rig(links: [SwitcherLink]) async throws -> Rig {
        let dir = temporaryFolder("switcher-start")
        var export = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("export")) as? [String: Any])
        var plots = try #require(export["plots"] as? [[String: Any]])
        let index = try #require(plots.firstIndex { ($0["id"] as? String) == plotID })
        plots[index]["links"] = links.enumerated().map { offset, link in
            ["id": link.linkID, "label": link.label, "target": link.target, "note": "", "position": offset + 1, "version": 1,
             "kind": link.kind.rawValue] as [String: Any]
        }
        export["plots"] = plots
        try JSONSerialization.data(withJSONObject: export).write(to: dir.appendingPathComponent("export.json"))
        try Fixtures.data("open_url").write(to: dir.appendingPathComponent("open.json"))
        try Fixtures.data("show").write(to: dir.appendingPathComponent("show.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1" in
              export) cat '\(d)/export.json';;
              open) cat '\(d)/open.json';;
              show) cat '\(d)/show.json';;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let file = AppStateFile(url: dir.appendingPathComponent("state.json"))
        let app = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]), stateFile: file)
        app.apply([PlotSummary(id: plotID, name: "Loam", what: "", createdAt: "2026-01-01T00:00:00Z"),
                   PlotSummary(id: "plotaaaaac", name: "Loam Docs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        app.activate(plot: "plotaaaaac")
        return Rig(dir: dir, app: app)
    }

    /// Opens the switcher, types the query, and waits for the links.
    func search(_ rig: Rig, _ query: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        rig.app.switcher.open()
        rig.app.switcher.query = query
        await waitUntil("the links show", sourceLocation: sourceLocation) {
            rig.app.switcher.results.contains { $0.item.kind == .link }
        }
    }

    @Test func commandReturnOnAnIssueLinkOpensTheNewWorktreeSheetFromTheLink() async throws {
        let rig = try await rig(links: [linear, issue, pull, notion])
        await search(rig, "ENG-482")
        #expect(rig.app.switcher.results.first?.item.title == linear.label)
        rig.app.switcher.chooseSelectedAlternate()
        let sheet = rig.app.newWorktreeSheet
        #expect(!rig.app.switcher.isOpen)
        #expect(sheet.isOpen && sheet.plotID == plotID)
        #expect(sheet.startLink?.id == linear.linkID)
        #expect(sheet.branch == "eng-482-link-kinds-for-figma")
        #expect(rig.app.workspace.activePlotID == plotID, "the sheet opens over the plot of the issue")
        await sheet.reading?.value
        #expect(rig.args().filter { $0.hasPrefix("open") }.isEmpty, "the link did not open")
    }

    @Test func returnOnTheSameLinkStillOpensIt() async throws {
        let rig = try await rig(links: [linear, issue, pull, notion])
        await search(rig, "ENG-482")
        rig.app.switcher.chooseSelected()
        #expect(!rig.app.switcher.isOpen)
        #expect(!rig.app.newWorktreeSheet.isOpen)
        await waitUntil("the link opened") { rig.args().contains { $0.hasPrefix("open") } }
        #expect(rig.args().contains("open \(plotID) \(linear.linkID) --json --actor app"))
    }

    @Test func commandReturnOnAGitHubIssueUsesItsNumber() async throws {
        let rig = try await rig(links: [linear, issue, pull, notion])
        await search(rig, "switcher width")
        let titles = rig.app.switcher.results.map(\.item.title)
        #expect(titles.contains(issue.label))
        rig.app.switcher.selection = try #require(titles.firstIndex(of: issue.label))
        rig.app.switcher.chooseSelectedAlternate()
        #expect(rig.app.newWorktreeSheet.branch == "57-fix-the-switcher-width")
        #expect(rig.app.newWorktreeSheet.goal == "Fix the switcher width")
    }

    @Test func commandReturnOnAnItemWithNoSecondActionDoesNothing() async throws {
        let rig = try await rig(links: [linear, issue, pull, notion])
        await search(rig, "Figma plan")
        #expect(rig.app.switcher.results.first?.item.title == notion.label)
        rig.app.switcher.chooseSelectedAlternate()
        #expect(rig.app.switcher.isOpen, "the switcher stays, so the key does not do what Return does")
        #expect(!rig.app.newWorktreeSheet.isOpen)
        #expect(rig.args().filter { $0.hasPrefix("open") }.isEmpty)
        // Also for a pull request.
        rig.app.switcher.query = "#58"
        rig.app.switcher.chooseSelectedAlternate()
        #expect(rig.app.switcher.isOpen && !rig.app.newWorktreeSheet.isOpen)
    }
}
