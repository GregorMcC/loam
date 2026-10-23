import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: a worktree that started from a link of the plot, which is still in the plot, gets a fourth box on the
/// Land sheet: "Remove ENG-482 from the plot's links". The data is made up (example/widgets, a Linear issue).
@Suite struct LandLinkContentTests {
    func plan(key: String = "ENG-482", linkID: String = "lnkaaaaaaa", edit: (inout LandResult) -> Void = { _ in }) throws -> LandResult {
        var plan = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
        plan.worktree.link = WorktreeLink(target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma",
                                          label: "ENG-482 Link kinds for Figma", key: key, linkID: linkID)
        edit(&plan)
        return plan
    }

    let link = PlotLink(id: "lnkaaaaaaa", label: "ENG-482 Link kinds for Figma",
                        target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma", note: "", position: 1, version: 3,
                        kind: .linear, exists: nil)

    @Test func theBoxNamesTheIssueKey() throws {
        let content = LandSheetContent(try plan(), openPanes: 0, startLink: link)
        #expect(content.removeLinkLabel == "Remove ENG-482 from the plot's links")
    }

    @Test func aLinkWithNoKeyIsNamedByItsLabel() throws {
        let content = LandSheetContent(try plan(key: ""), openPanes: 0, startLink: link)
        #expect(content.removeLinkLabel == "Remove ENG-482 Link kinds for Figma from the plot's links")
    }

    @Test func noLinkInThePlotHasNoBox() throws {
        #expect(LandSheetContent(try plan(), openPanes: 0).removeLinkLabel == nil)
        #expect(LandSheetContent(try plan(), openPanes: 0, startLink: nil).removeLinkName == nil)
    }

    @Test func aMergeThatWaitsHasNoBox() throws {
        let waiting = try plan {
            $0.checks[0] = LandCheck(name: "checks", state: "running", blocks: false)
        }
        let content = LandSheetContent(waiting, openPanes: 0, startLink: link)
        #expect(content.usesAuto)
        #expect(content.removeLinkLabel == nil)
        let queued = LandSheetContent(try plan { $0.mergeQueue = true }, openPanes: 0, startLink: link)
        #expect(queued.mergeQueue && queued.removeLinkLabel == nil)
    }

    @Test func aPullRequestThatIsMergedAlreadyHasNoBox() throws {
        let merged = LandSheetContent(try plan { $0.merged = true }, openPanes: 0, startLink: link)
        #expect(merged.isMerged && merged.removeLinkLabel == nil)
    }
}

@MainActor
@Suite struct LandLinkModelTests {
    let plotID = "plotaaaaab"
    let ready = "wtreaaaaao"
    let linkID = "lnkaaaaaaa"

    @MainActor final class Rig {
        let dir: URL
        let model: AppModel
        var toasts: [(text: String, kind: ActionBarModel.ToastKind)] = []
        var ownChanges: [Int] = []

        init(dir: URL, model: AppModel) {
            self.dir = dir
            self.model = model
        }

        func args() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("args.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func calls(_ command: String) -> [String] { args().filter { $0.hasPrefix(command) } }
        func touch(_ name: String, _ text: String = "") throws { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    }

    /// A model whose plot has the link `lnkaaaaaaa` (unless `inPlot` is false) and whose plan for `link-labels` says that the
    /// work started from it (unless `linkID` is empty, as for a URL).
    func rig(inPlot: Bool = true, startedFrom startID: String? = nil, key: String = "ENG-482") async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("land-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = try Fixtures.data("worktree_list_stages")
        try rows.write(to: dir.appendingPathComponent("list.json"))
        let left = try (JSONSerialization.jsonObject(with: rows) as? [[String: Any]] ?? []).filter {
            (($0["worktree"] as? [String: Any])?["id"] as? String) != ready
        }
        try JSONSerialization.data(withJSONObject: left).write(to: dir.appendingPathComponent("list-after.json"))
        for name in ["worktree_land", "set", "link_rm", "error_stale", "error_generic"] {
            try Fixtures.data(name).write(to: dir.appendingPathComponent("\(name).json"))
        }
        var plan = try JSONDecoder().decode(LandResult.self, from: Fixtures.data("worktree_land_dry_run"))
        plan.worktree.link = WorktreeLink(target: "https://linear.app/example/issue/ENG-482/link-kinds-for-figma",
                                          label: "ENG-482 Link kinds for Figma", key: key, linkID: startID ?? linkID)
        try JSONEncoder().encode(plan).write(to: dir.appendingPathComponent("dry.json"))
        var show = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("show")) as? [String: Any])
        show["links"] = inPlot
            ? [["id": linkID, "kind": "linear", "label": "ENG-482 Link kinds for Figma", "note": "", "position": 1, "version": 3,
                "target": "https://linear.app/example/issue/ENG-482/link-kinds-for-figma"] as [String: Any]]
            : []
        show["where_it_stands"] = "Native panel spacing fails lint."
        show["versions"] = ["name": 1, "what": 1, "why": 1, "where": 4, "link:\(linkID)": 3]
        try JSONSerialization.data(withJSONObject: show).write(to: dir.appendingPathComponent("show.json"))
        let d = dir.path
        try FakeScript.install("""
            #!/bin/sh
            echo "$@" >> '\(d)/args.log'
            case "$1 $2" in
              "show "*) cat '\(d)/show.json';;
              "set "*) cat > /dev/null; cat '\(d)/set.json';;
              "link rm")
                [ -f '\(d)/fail-link-stale' ] && { cat '\(d)/error_stale.json'; exit 10; }
                [ -f '\(d)/fail-link' ] && { cat '\(d)/error_generic.json'; exit 1; }
                cat '\(d)/link_rm.json';;
              "worktree land")
                case "$*" in
                  *--dry-run*) cat '\(d)/dry.json';;
                  *) [ -f '\(d)/fail-land' ] && { cat '\(d)/error_generic.json'; exit 1; }
                    touch '\(d)/landed'
                    cat '\(d)/worktree_land.json';;
                esac;;
              "worktree list") if [ -f '\(d)/landed' ]; then cat '\(d)/list-after.json'; else cat '\(d)/list.json'; fi;;
              *) exit 1;;
            esac
            """, at: dir.appendingPathComponent("loam"))
        let model = AppModel(client: LoamClient(binary: dir.appendingPathComponent("loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.apply([PlotSummary(id: plotID, name: "Widgets", what: "", createdAt: "2026-01-01T00:00:00Z")])
        await model.reloadWorktrees()
        let rig = Rig(dir: dir, model: model)
        model.onToast = { rig.toasts.append(($0, $1)) }
        model.onOwnChange = { rig.ownChanges.append($0) }
        return rig
    }

    func open(_ rig: Rig) async throws -> LandSheetContent {
        #expect(rig.model.openLandSheet(ready))
        let deadline = Date().addingTimeInterval(5)
        while rig.model.landSheet.plan == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return try #require(rig.model.landContent)
    }

    // MARK: The box

    @Test func theBoxShowsWhenTheLinkIsStillInThePlotAndIsOnAtFirst() async throws {
        let rig = try await rig()
        let content = try await open(rig)
        #expect(content.removeLinkLabel == "Remove ENG-482 from the plot's links")
        #expect(rig.model.landSheet.removesLink)
        #expect(rig.model.landSheet.startLink?.id == linkID)
        #expect(rig.calls("show") == ["show \(plotID) --json"], "the plot is read once")
    }

    @Test func noBoxWhenTheLinkIsGoneFromThePlot() async throws {
        let rig = try await rig(inPlot: false)
        let content = try await open(rig)
        #expect(content.removeLinkLabel == nil && rig.model.landSheet.startLink == nil)
    }

    @Test func noBoxForAWorktreeThatStartedFromAUrl() async throws {
        let rig = try await rig(startedFrom: "")
        let content = try await open(rig)
        #expect(content.removeLinkLabel == nil)
    }

    @Test func aNewOpenIsOnAgain() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        rig.model.landSheet.removesLink = false
        rig.model.closeLandSheet()
        _ = try await open(rig)
        #expect(rig.model.landSheet.removesLink)
    }

    // MARK: The merge

    @Test func aMergeRemovesTheLinkAsAChangeAfterTheLand() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        await rig.model.land()
        let calls = rig.args().filter { $0.hasPrefix("worktree land") && !$0.contains("--dry-run") || $0.hasPrefix("link rm") }
        #expect(calls.count == 2 && calls[0].hasPrefix("worktree land"))
        #expect(calls[1] == "link rm \(plotID) \(linkID) --expect link:\(linkID)=3 --json --actor app")
        #expect(rig.ownChanges.contains(8), "the toast of the app stands, and the log does not replace it")
        #expect(rig.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels. Removed ENG-482 from the plot's links."])
        #expect(rig.toasts.first?.kind == .done)
        #expect(!rig.model.landSheet.isOpen)
    }

    @Test func theBoxOffKeepsTheLink() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        rig.model.landSheet.removesLink = false
        await rig.model.land()
        #expect(rig.calls("link rm").isEmpty)
        #expect(rig.toasts.map(\.text) == ["Merged #22. Removed the worktree link-labels."])
    }

    @Test func theLinkGoesEvenWhenWhereItStandsStays() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        rig.model.landSheet.movesWhereItStandsOn = false
        await rig.model.land()
        #expect(rig.calls("set").isEmpty)
        #expect(rig.calls("link rm").count == 1)
    }

    @Test func aMergeThatFailsRemovesNothing() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        try rig.touch("fail-land")
        await rig.model.land()
        #expect(rig.calls("link rm").isEmpty)
        #expect(rig.model.landSheet.isOpen && rig.model.landSheet.landError != nil)
    }

    @Test func aLinkThatChangedMeanwhileIsNotRemovedAndTheToastSaysSo() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        try rig.touch("fail-link-stale")
        await rig.model.land()
        #expect(rig.calls("link rm").count == 1)
        #expect(!rig.model.landSheet.isOpen, "the merge is done")
        let toast = try #require(rig.toasts.first)
        #expect(toast.text == "Merged #22. Removed the worktree link-labels. ENG-482 changed in the plot meanwhile, so Loam did not remove it.")
        #expect(toast.kind == .notice)
    }

    @Test func anyOtherFailureIsANoticeWithTheMessage() async throws {
        let rig = try await rig()
        _ = try await open(rig)
        try rig.touch("fail-link")
        await rig.model.land()
        let toast = try #require(rig.toasts.first)
        #expect(toast.text.hasPrefix("Merged #22. Removed the worktree link-labels. Loam could not remove ENG-482 from the plot's links: "))
        #expect(toast.kind == .notice)
        #expect(!rig.model.landSheet.isOpen)
    }
}
