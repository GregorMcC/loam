import Foundation
import Testing
@testable import LoamKit

private func plot(_ id: String, _ name: String) -> PlotSummary {
    PlotSummary(id: id, name: name, what: "", createdAt: "2026-01-01T00:00:00Z")
}

private func item(_ id: String, _ kind: SwitcherItem.Kind, _ title: String, other: [String] = [],
                  plotName: String? = nil, attention: PaneAttention = .none) -> SwitcherItem {
    SwitcherItem(id: id, kind: kind, title: title, otherText: other, plotName: plotName,
                 attention: attention, target: .action(id))
}

private func ids(_ results: [SwitcherResult]) -> [String] { results.map(\.item.id) }

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite struct FuzzyMatcherTests {
    @Test func needsEveryLetterInOrder() {
        #expect(FuzzyMatcher.match("lmx", in: "Loam Docs") == nil)
        #expect(FuzzyMatcher.match("ldc", in: "Loam Docs")?.indices == [0, 5, 7])
    }

    @Test func ignoresCase() {
        #expect(FuzzyMatcher.match("LOAM", in: "loam")?.indices == [0, 1, 2, 3])
    }

    @Test func aRunBeatsScatteredLetters() throws {
        let run = try #require(FuzzyMatcher.match("auth", in: "auth fix"))
        let scattered = try #require(FuzzyMatcher.match("auth", in: "a big unusual thing"))
        #expect(run.score > scattered.score)
    }

    @Test func aWordStartBeatsTheMiddleOfAWord() throws {
        let start = try #require(FuzzyMatcher.match("fix", in: "auth fix"))
        let middle = try #require(FuzzyMatcher.match("fix", in: "suffix"))
        #expect(start.score > middle.score)
    }

    @Test func anExactMatchBeatsALongerText() throws {
        let exact = try #require(FuzzyMatcher.match("loam", in: "Loam"))
        let longer = try #require(FuzzyMatcher.match("loam", in: "Loam Docs"))
        #expect(exact.score > longer.score)
    }

    @Test func prefersTheBestAlignmentNotTheFirst() {
        // "ab" matches at 0 and 1 in "a-ab" only if the first "a" is skipped for the run.
        #expect(FuzzyMatcher.match("ab", in: "a-ab")?.indices == [2, 3])
    }

    @Test func aWordLongerThanTheTextDoesNotMatch() {
        #expect(FuzzyMatcher.match("loamloam", in: "loam") == nil)
        #expect(FuzzyMatcher.match("", in: "loam") == nil)
    }
}

@Suite struct SwitcherRankerTests {
    // MARK: Empty query

    /// Panes that need you, then done and unread, then plots and panes by use. No links, no actions.
    @Test func emptyQueryOrderWithFakeAttention() {
        let items = [
            item("plot:a", .plot, "Alpha"),
            item("plot:b", .plot, "Beta"),
            item("pane:1", .pane, "idle one", attention: .none),
            item("pane:2", .pane, "needs older", attention: .needsYou),
            item("pane:3", .pane, "done old", attention: .doneUnread),
            item("pane:4", .pane, "needs newer", attention: .needsYou),
            item("pane:5", .pane, "done new", attention: .doneUnread),
            item("link:a:1", .link, "A link"),
            item("action:x", .action, "New Tab"),
        ]
        let uses: [String: Date] = [
            "pane:2": at(10), "pane:4": at(20),
            "pane:3": at(30), "pane:5": at(40),
            "plot:b": at(50), "pane:1": at(60), "plot:a": at(5),
        ]
        let order = ids(SwitcherRanker.rank(items, query: "", useTimes: uses))
        #expect(order == [
            "pane:4", "pane:2",          // needs you, newest use first
            "pane:5", "pane:3",          // done, unread
            "pane:1", "plot:b", "plot:a", // the rest by use
        ])
    }

    @Test func emptyQueryPutsUnusedItemsAfterUsedOnesInSourceOrder() {
        let items = [
            item("plot:a", .plot, "Alpha"), item("plot:b", .plot, "Beta"),
            item("pane:1", .pane, "shell"), item("pane:2", .pane, "shell"),
        ]
        let order = ids(SwitcherRanker.rank(items, query: "", useTimes: ["pane:2": at(1)]))
        #expect(order == ["pane:2", "plot:a", "plot:b", "pane:1"])
    }

    @Test func aWhitespaceQueryIsEmpty() {
        let items = [item("plot:a", .plot, "Alpha"), item("link:1", .link, "Alpha docs")]
        #expect(ids(SwitcherRanker.rank(items, query: "  ", useTimes: [:])) == ["plot:a"])
    }

    // MARK: Typed query

    @Test func typedQueryRanksByScoreThenRecency() {
        let items = [
            item("plot:old", .plot, "Notes old"),
            item("plot:new", .plot, "Notes new"),
            item("link:1", .link, "My notes page"),
            item("plot:exact", .plot, "Notes"),
        ]
        // "Notes" is exact and wins. "Notes old" and "Notes new" score the same: recency breaks the tie.
        let uses = ["plot:new": at(100), "plot:old": at(50)]
        let order = ids(SwitcherRanker.rank(items, query: "notes", useTimes: uses))
        #expect(order.first == "plot:exact")
        #expect(order.firstIndex(of: "plot:new")! < order.firstIndex(of: "plot:old")!)
        #expect(order.last == "link:1")
    }

    @Test func equalScoresAndNoUseKeepSourceOrder() {
        let items = [item("plot:a", .plot, "Same"), item("plot:b", .plot, "Same")]
        #expect(ids(SwitcherRanker.rank(items, query: "same", useTimes: [:])) == ["plot:a", "plot:b"])
        #expect(ids(SwitcherRanker.rank(items, query: "same", useTimes: ["plot:b": at(1)])) == ["plot:b", "plot:a"])
    }

    @Test func attentionDoesNotChangeTypedOrder() {
        let items = [
            item("pane:1", .pane, "build", attention: .needsYou),
            item("pane:2", .pane, "build", attention: .none),
        ]
        let order = ids(SwitcherRanker.rank(items, query: "build", useTimes: ["pane:2": at(9)]))
        #expect(order == ["pane:2", "pane:1"])
    }

    @Test func aPaneMatchesOnItsTitleAndItsPlotNameAcrossWords() {
        let items = [
            item("pane:1", .pane, "auth fix", other: ["Loam"], plotName: "Loam"),
            item("pane:2", .pane, "auth fix", other: ["Strata"], plotName: "Strata"),
        ]
        #expect(ids(SwitcherRanker.rank(items, query: "loam auth", useTimes: [:])) == ["pane:1"])
    }

    @Test func aLinkMatchesOnLabelTargetAndPlotName() {
        let items = [item("link:1", .link, "Design doc", other: ["https://notion.so/abc", "Loam"], plotName: "Loam")]
        #expect(ids(SwitcherRanker.rank(items, query: "design", useTimes: [:])) == ["link:1"])
        #expect(ids(SwitcherRanker.rank(items, query: "notion", useTimes: [:])) == ["link:1"])
        #expect(ids(SwitcherRanker.rank(items, query: "loam", useTimes: [:])) == ["link:1"])
        #expect(SwitcherRanker.rank(items, query: "zzz", useTimes: [:]).isEmpty)
    }

    @Test func aTitleMatchBeatsTheSameWordInThePlotName() {
        let items = [
            item("pane:1", .pane, "shell", other: ["Loam"], plotName: "Loam"),
            item("plot:1", .plot, "Loam"),
        ]
        #expect(ids(SwitcherRanker.rank(items, query: "loam", useTimes: [:])) == ["plot:1", "pane:1"])
    }

    @Test func listsTheTitleLettersToHighlight() {
        let result = SwitcherRanker.rank([item("plot:1", .plot, "Loam Docs")], query: "ld", useTimes: [:])
        #expect(result.first?.titleMatches == [0, 5])
    }

    // MARK: Action filter

    @Test func greaterThanLimitsTheListToActions() {
        let items = [
            item("plot:1", .plot, "Split plot"),
            item("action:a", .action, "Split Right"),
            item("action:b", .action, "Split Down"),
            item("action:c", .action, "New Tab"),
        ]
        #expect(ids(SwitcherRanker.rank(items, query: ">", useTimes: [:])) == ["action:a", "action:b", "action:c"])
        #expect(ids(SwitcherRanker.rank(items, query: ">split", useTimes: [:])) == ["action:a", "action:b"])
        #expect(ids(SwitcherRanker.rank(items, query: "> down", useTimes: [:])) == ["action:b"])
        // Without the prefix, the plot shows too.
        #expect(ids(SwitcherRanker.rank(items, query: "split", useTimes: [:])).contains("plot:1"))
    }

    @Test func theActionFilterKeepsMenuOrderForAnEmptyWord() {
        let items = [item("action:z", .action, "Zoom"), item("action:a", .action, "About")]
        #expect(ids(SwitcherRanker.rank(items, query: ">", useTimes: ["action:a": at(5)])) == ["action:z", "action:a"])
    }

    @Test func parsesThePrefix() {
        #expect(SwitcherRanker.parse(">x").actionsOnly)
        #expect(SwitcherRanker.parse(">x").text == "x")
        #expect(!SwitcherRanker.parse("x>").actionsOnly)
    }
}

@MainActor
@Suite struct SwitcherModelTests {
    func tempFile() -> AppStateFile {
        AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-\(UUID().uuidString)/state.json"))
    }

    func model(_ file: AppStateFile? = nil) -> AppModel {
        let model = AppModel(client: LoamClient(), stateFile: file ?? tempFile())
        model.apply([plot("p1", "Alpha"), plot("p2", "Beta")], archived: [plot("p3", "Gone")])
        return model
    }

    @Test func buildsItemsForPlotsPanesSavedPanesLinksAndActionsOfPlotsThatAreNotArchived() {
        let app = model()
        app.activate(plot: "p2")
        app.openTab()
        let pane = app.workspace.selectedTab(of: "p2")!.focused
        app.setTerminalTitle("auth fix", of: pane)
        app.apply([plot("p1", "Alpha"), plot("p2", "Beta")], archived: [plot("p3", "Gone")])

        let items = SwitcherModel.items(
            plots: app.plots, workspace: app.workspace, terminalTitles: app.terminalTitles,
            attention: { $0 == pane ? .needsYou : .none },
            savedPanes: [SavedPane(id: "saved-1", plotID: "p1", title: "old session", attention: .doneUnread),
                         SavedPane(id: "saved-2", plotID: "p3", title: "archived session")],
            links: [SwitcherLink(plotID: "p1", linkID: "l1", label: "Docs", target: "https://github.com/a/b",
                                 kind: .github),
                    SwitcherLink(plotID: "p3", linkID: "l2", label: "Hidden", target: "x")],
            actions: [SwitcherAction(id: "File/New Tab", title: "New Tab", shortcut: "⌘T")])

        #expect(items.map(\.id) == [
            "plot:p1", "plot:p2", "pane:\(pane.uuidString)", "pane:saved-1", "link:p1:l1", "action:File/New Tab",
        ])
        let live = items[2]
        #expect(live.title == "auth fix")
        #expect(live.otherText == ["Beta"])
        #expect(live.attention == .needsYou)
        #expect(items[3].attention == .doneUnread)
        #expect(items[4].otherText == ["https://github.com/a/b", "Alpha"])
        #expect(items[5].shortcut == "⌘T")
        #expect(items[0].icon == .plot)
        #expect(live.icon == .pane(app.workspace.spec(of: pane)!.kind))
        #expect(items[4].icon == .brand(.github))
        #expect(items[5].icon == .action)
    }

    @Test func aPaneWithNoTerminalTitleUsesItsSpecTitle() {
        let app = model()
        app.openTab()
        let items = SwitcherModel.items(
            plots: app.plots, workspace: app.workspace, terminalTitles: [:], attention: { _ in .none },
            savedPanes: [], links: [], actions: [])
        #expect(items.filter { $0.kind == .pane }.map(\.title) == ["shell"])
    }

    @Test func opensOnAllItemsOrOnActions() {
        let app = model()
        app.switcher.actions = { [SwitcherAction(id: "a", title: "New Tab")] }
        app.switcher.open()
        #expect(app.switcher.isOpen)
        #expect(app.switcher.query == "")
        #expect(app.switcher.results.map(\.item.id) == ["plot:p1", "plot:p2"])
        app.switcher.close()
        app.switcher.open(actionsOnly: true)
        #expect(app.switcher.query == ">")
        #expect(app.switcher.results.map(\.item.id) == ["action:a"])
        app.switcher.close()
        #expect(!app.switcher.isOpen)
    }

    @Test func returnOnAPlotMakesItActiveAndRecordsTheUse() {
        let file = tempFile()
        let app = model(file)
        let writer = AppStateWriter(file: file)
        app.useTimes = UseTimes(writer: writer)
        app.switcher.open()
        app.switcher.query = "beta"
        #expect(app.switcher.results.first?.item.id == "plot:p2")
        app.switcher.chooseSelected()
        #expect(app.workspace.activePlotID == "p2")
        #expect(!app.switcher.isOpen)
        writer.flush()
        let stored = file.value(forKey: UseTimes.key) as? [String: Double]
        #expect(stored?["plot:p2"] != nil)
    }

    @Test func returnOnAPaneMakesItsPlotActiveAndFocusesIt() {
        let app = model()
        app.activate(plot: "p2")
        app.openTab()
        let first = app.workspace.selectedTab(of: "p2")!.focused
        app.setTerminalTitle("zebra", of: first)
        app.openTab()
        app.activate(plot: "p1")
        app.switcher.open()
        app.switcher.query = "zebra"
        app.switcher.chooseSelected()
        #expect(app.workspace.activePlotID == "p2")
        #expect(app.workspace.selectedTab(of: "p2")?.focused == first)
    }

    @Test func returnOnAPaneThatAlreadyHasFocusMovesItUpTheEmptyQueryList() {
        let file = tempFile()
        let app = model(file)
        let times = UseTimes(writer: AppStateWriter(file: file))
        app.useTimes = times
        app.activate(plot: "p2")
        app.openTab()
        let pane = app.workspace.selectedTab(of: "p2")!.focused  // Focused already in its plot.
        app.setTerminalTitle("zebra", of: pane)
        let old = Date(timeIntervalSinceNow: -1000)
        times.record("plot:p1", at: old)
        times.record("plot:p2", at: old)
        app.activate(plot: "p1")
        app.switcher.open()
        app.switcher.query = "zebra"
        app.switcher.chooseSelected()
        #expect(app.workspace.activePlotID == "p2")
        #expect(times.all[SwitcherItem.paneKey(pane.uuidString)] != nil)
        app.switcher.open()
        #expect(app.switcher.results.first?.item.id == SwitcherItem.paneKey(pane.uuidString))
    }

    @Test func returnOnASavedPaneShowsItsPlotAndAsksForTheResume() {
        let app = model()
        var resumed: SavedPane?
        app.switcher.savedPanes = { [SavedPane(id: "s1", plotID: "p2", title: "old session")] }
        app.switcher.resumeSavedPane = { resumed = $0 }
        app.switcher.open()
        app.switcher.query = "old"
        app.switcher.chooseSelected()
        #expect(app.workspace.activePlotID == "p2")
        #expect(resumed?.id == "s1")
    }

    @Test func returnOnAnActionRunsIt() {
        let app = model()
        var ran: String?
        app.switcher.actions = { [SwitcherAction(id: "View/Toggle Sidebar", title: "Toggle Sidebar")] }
        app.switcher.runAction = { ran = $0 }
        app.switcher.open(actionsOnly: true)
        app.switcher.query = ">side"
        app.switcher.chooseSelected()
        #expect(ran == "View/Toggle Sidebar")
    }

    @Test func theListHoldsAtMostTheRowsThatShow() {
        let app = model()
        app.switcher.actions = { (0..<100).map { SwitcherAction(id: "a\($0)", title: "Action \($0)") } }
        app.switcher.open(actionsOnly: true)
        #expect(app.switcher.results.count == SwitcherModel.maxRows)
        app.switcher.moveSelection(500)
        #expect(app.switcher.selection == SwitcherModel.maxRows - 1)
    }

    @Test func theSelectionStaysInTheList() {
        let app = model()
        app.switcher.open()
        app.switcher.moveSelection(-1)
        #expect(app.switcher.selection == 0)
        app.switcher.moveSelection(5)
        #expect(app.switcher.selection == 1)
    }

    @Test func recentUseMovesAPlotToTheTop() {
        let file = tempFile()
        let app = model(file)
        app.useTimes = UseTimes(writer: AppStateWriter(file: file))
        app.activate(plot: "p2")
        app.switcher.open()
        #expect(app.switcher.results.first?.item.id == "plot:p2")
    }
}

@Suite struct SwitcherSectionTests {
    private func result(_ id: String, _ kind: SwitcherItem.Kind) -> SwitcherResult {
        SwitcherResult(item: item(id, kind, id), score: 0, titleMatches: [])
    }

    @Test func groupsByKindInTheOrderOfEachKindsBestResult() {
        let ranked = [result("a", .pane), result("b", .plot), result("c", .pane), result("d", .link), result("e", .plot)]
        #expect(ids(SwitcherModel.grouped(ranked)) == ["a", "c", "b", "e", "d"])
    }

    @MainActor @Test func sectionsCoverTheRowsOfEachKind() {
        let app = AppModel(client: LoamClient(), stateFile: AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sections-\(UUID().uuidString)/state.json")))
        app.apply([plot("p1", "Alpha"), plot("p2", "Beta")])
        let switcher = SwitcherModel()
        switcher.app = app
        switcher.actions = { [SwitcherAction(id: "x", title: "New Tab")] }
        switcher.open()
        switcher.query = "a"  // Alpha, Beta, and New Tab.
        let sections = switcher.sections
        #expect(Set(sections.map(\.kind)) == [.plot, .action])
        #expect(sections.flatMap(\.rows) == Array(switcher.results.indices))
        for section in sections {
            #expect(section.rows.allSatisfy { switcher.results[$0].item.kind == section.kind })
        }
    }
}

@MainActor
@Suite struct UseTimesTests {
    func tempFile() -> AppStateFile {
        AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("usetimes-\(UUID().uuidString)/state.json"))
    }

    @Test func keepsTimesInStateJsonAndOtherKeys() throws {
        let file = tempFile()
        try file.setValue(["p1": 3], forKey: AppStateFile.lastSeenKey)
        let writer = AppStateWriter(file: file)
        let times = UseTimes(writer: writer)
        times.record("plot:p1", at: at(100))
        times.record("link:p1:l1", at: at(200))
        writer.flush()
        let again = UseTimes(writer: AppStateWriter(file: file))
        #expect(again.all == ["plot:p1": at(100), "link:p1:l1": at(200)])
        #expect(file.lastSeenChanges() == ["p1": 3])
    }

    @Test func dropsTheOldestEntriesPastTheLimit() {
        let times = UseTimes(writer: AppStateWriter(file: tempFile()))
        for n in 0...UseTimes.limit { times.record("pane:\(n)", at: at(Double(n))) }
        #expect(times.all.count == UseTimes.limit)
        #expect(times.all["pane:0"] == nil)
        #expect(times.all["pane:\(UseTimes.limit)"] != nil)
    }
}
