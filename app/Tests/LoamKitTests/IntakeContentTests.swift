import Foundation
import Testing

@testable import LoamKit

/// The Intake page: the sources it reads, the source switch, the filter chips and the sort, the Run column, the name
/// of a run worktree, and the bar of the checked rows.
@MainActor
@Suite(.waitLimit) struct IntakeContentTests {
    static func item(_ source: String, key: String, priority: String = "", created: String = "2026-10-01T00:00:00Z",
                     run: String = "", inCycle: Bool = false, mine: Bool = false) -> IntakeItem {
        var item = IntakeItem(source: source, key: key, title: "Title of \(key)", status: "Open", priority: priority, labels: [],
                              url: "https://example.com/\(key)", updatedAt: "", runID: run)
        item.createdAt = created
        item.inCycle = inCycle
        item.assignedToMe = mine
        return item
    }

    static func list(_ items: [IntakeItem], sources: [IntakeSource] = []) -> IntakeList {
        IntakeList(plotID: "p", sources: sources, items: items)
    }

    @Test func theReadsLineNamesEachSource() {
        let sources = [IntakeSource(kind: "linear", label: "ENG team", error: ""),
                       IntakeSource(kind: "linear", label: "Loam project", error: ""),
                       IntakeSource(kind: "github", label: "example/widgets", error: ""),
                       IntakeSource(kind: "map", label: "Build map", error: "")]
        #expect(IntakeContent.readsLine(sources)
            == "From the plot's links: Linear ENG team, Loam project \u{00B7} GitHub example/widgets \u{00B7} the plot's map")
        #expect(IntakeContent.readsLine(Array(sources.suffix(1)) + Array(sources.suffix(1)))
            == "From the plot's links: the plot's maps")
        #expect(IntakeContent.readsLine([]) == "")
    }

    @Test func theSourceSwitchShowsOnlyTheSourcesThatExist() {
        let list = Self.list([Self.item("linear", key: "ENG-1"), Self.item("map", key: "map 2"), Self.item("map", key: "map 3")],
                             sources: [IntakeSource(kind: "github", label: "example/widgets", error: "gh is missing")])
        #expect(IntakeContent.sourceChoices(list).map(\.words) == ["All 3", "Linear 1", "GitHub 0", "The map 2"])
        #expect(IntakeContent.sourceChoices(Self.list([])).map(\.words) == ["All 0"])
        #expect(IntakeContent.showsThisCycle(list))
        #expect(!IntakeContent.showsThisCycle(Self.list([Self.item("map", key: "map 2")])))
    }

    @Test func theRowsGoByPriorityThenAgeWithTheRunsLast() {
        let list = Self.list([
            Self.item("linear", key: "ENG-1", priority: "Low"),
            Self.item("linear", key: "ENG-2", priority: "High", run: "run1"),
            Self.item("github", key: "#3", created: "2026-09-01T00:00:00Z"),
            Self.item("linear", key: "ENG-4", priority: "High", created: "2026-10-02T00:00:00.000Z"),
            Self.item("linear", key: "ENG-5", priority: "Urgent"),
            Self.item("linear", key: "ENG-6", priority: "High", created: "2026-09-30T00:00:00.000Z"),
            Self.item("map", key: "map 7", created: ""),
            Self.item("map", key: "map 8", created: ""),
        ])
        #expect(IntakeContent.rows(list, filter: .init()).map(\.key)
            == ["ENG-5", "ENG-6", "ENG-4", "ENG-1", "#3", "map 7", "map 8", "ENG-2"])
    }

    @Test func theChipsAndTheSwitchFilterTheRows() {
        let list = Self.list([
            Self.item("linear", key: "ENG-1", inCycle: true, mine: true),
            Self.item("linear", key: "ENG-2", run: "run1", inCycle: true),
            Self.item("github", key: "#3", mine: true),
            Self.item("map", key: "map 4"),
        ])
        func keys(_ change: (inout IntakeContent.Filter) -> Void) -> [String] {
            var filter = IntakeContent.Filter()
            change(&filter)
            return IntakeContent.rows(list, filter: filter).map(\.key)
        }
        #expect(keys { $0.source = .map } == ["map 4"])
        #expect(keys { $0.thisCycle = true } == ["ENG-1", "ENG-2"])
        #expect(keys { $0.assignedToMe = true } == ["ENG-1", "#3"])
        #expect(keys { $0.hideWithRun = true } == ["ENG-1", "#3", "map 4"])
        #expect(keys { $0.source = .linear; $0.hideWithRun = true } == ["ENG-1"])
    }

    @Test func theColumnsSayTheStatusAndThePriority() {
        var item = Self.item("github", key: "#48")
        item.labels = ["bug"]
        #expect(IntakeContent.statusWords(item) == "Open \u{00B7} bug")
        #expect(IntakeContent.priorityWords(item) == "None")
        #expect(IntakeContent.statusLine(item) == "Open")
        item.priority = "High"
        #expect(IntakeContent.statusLine(item) == "Open \u{00B7} High")
    }

    @Test func theRunColumnSaysTheStationOfTheRun() throws {
        let runs = try JSONDecoder().decode([Run].self, from: Fixtures.data("run_list"))
        var run = try #require(runs.first)
        run.shape = nil
        run.pr = nil
        func words(_ state: RunState, tries: Int = 0, pr: Int? = nil) -> String {
            run.state = state
            run.tries = tries
            run.maxTries = 3
            run.pr = pr.map { RunPR(number: $0, url: "") }
            return IntakeContent.runWords(run).words
        }
        #expect(IntakeContent.runWords(nil) == ("None", .none))
        #expect(words(.shaping) == "Shape, waits for you")
        #expect(words(.queued) == "Waits for a slot")
        #expect(words(.running, tries: 1) == "Run, try 2 of 3")
        #expect(words(.running, tries: 3) == "Run, try 3 of 3")
        #expect(words(.shipping, pr: 146) == "Ship #146")
        #expect(words(.ready, pr: 147) == "Land #147")
        #expect(words(.limited) == "Stopped by a limit")
        #expect(words(.cancelled) == "Cancelled")
        run.state = .ready
        #expect(IntakeContent.runWords(run).mark == .ready)
        run.state = .stopped
        #expect(IntakeContent.runWords(run).mark == .needsYou)
    }

    /// The cases of the core: a run with no key, a map ticket, and a name that a worktree of the plot has.
    @Test func theWorktreeNameIsTheNameThatTheCoreGives() {
        #expect(RunWorktreeName.name(title: "Drag a link to reorder", key: "", taken: []) == "drag-a-link-to-reorder")
        #expect(RunWorktreeName.name(title: "Fix the thing", key: "", taken: []) == "fix-the-thing")
        #expect(RunWorktreeName.name(title: "Quit during a merge", key: "map 135", taken: [])
            == "map-135-quit-during-a-merge")
        #expect(RunWorktreeName.name(title: "Plot panel: drag a link to reorder it", key: "ENG-523", taken: [])
            == "eng-523-plot-panel-drag-a-link-to-reorder-it")
        #expect(RunWorktreeName.name(title: "Fix x", key: "#48", taken: ["48-fix-x", "48-fix-x-2"]) == "48-fix-x-3")
        #expect(RunWorktreeName.name(title: "Ünïcode — only?", key: "", taken: []) == "n-code-only")
        #expect(RunWorktreeName.name(title: "—", key: "", taken: []) == "run")
    }

    @Test func aLongNameEndsAtAWholeWord() {
        let name = RunWorktreeName.name(title: "Settings: choose the folder that each worktree goes into", key: "ENG-1",
                                        taken: [])
        #expect(name == "eng-1-settings-choose-the-folder-that-each")
        #expect(name.count <= 48)
        #expect(RunWorktreeName.slug(String(repeating: "a", count: 60)) == String(repeating: "a", count: 48))
    }

    @Test func theDetailSaysWhereTheItemComesFrom() {
        #expect(IntakeContent.fromWords(Self.item("linear", key: "ENG-1"))
            == "From Linear. The run gets the link to this issue, not a copy of the text.")
        #expect(IntakeContent.openWords(Self.item("github", key: "#1")) == "Open on GitHub")
        #expect(IntakeContent.openWords(Self.item("map", key: "map 1")) == "Open the ticket")
    }

    @Test func theBarSaysWhatItsButtonDoes() {
        #expect(IntakeContent.batchButton(count: 3, kind: .feature) == "Shape 3 runs")
        #expect(IntakeContent.batchButton(count: 1, kind: .chore) == "Start 1 run")
        #expect(IntakeContent.batchCaption(count: 3, kind: .feature, split: false)
            == "Claude shapes all 3 now. Each run waits for a slot after you approve it.")
        #expect(IntakeContent.batchCaption(count: 1, kind: .feature, split: true)
            == "Claude splits it across the repos now. The run waits for a slot after you approve it.")
        #expect(IntakeContent.shapeChoices(repoCount: 1).map(\.words) == ["Now"])
        #expect(IntakeContent.shapeChoices(repoCount: 2).map(\.words) == ["Now", "Split across the repos"])
    }

    @Test func onlyAShapeSplits() {
        var item = Self.item("github", key: "#1")
        item.repo = "repob"
        let shape = IntakeContent.batchDrafts([item], kind: .feature, split: true)
        #expect(shape.first?.split == true && shape.first?.repo == nil)
        let chore = IntakeContent.batchDrafts([item], kind: .chore, split: true)
        #expect(chore.first?.split == false && chore.first?.repo == "repob" && chore.first?.goal == "")
    }

    // MARK: The model

    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    @Test func theBarShapesEachItemInTurnAndStaysOnThePage() async throws {
        let (model, fake) = try model([("intake_list", 0), ("run_shape", 0), ("run_shape", 0), ("run_list", 0), ("intake_list", 0)])
        await model.showIntake(plot: "plotaaaaae")
        let items = try #require(model.intake?.items).filter { $0.runID.isEmpty }.prefix(2)
        let drafts = IntakeContent.batchDrafts(Array(items), kind: .feature, split: false)
        #expect(await model.startIntakeBatch(plot: "plotaaaaae", drafts: drafts, shape: true) == 2)
        #expect(model.page == .intake("plotaaaaae") && model.runStartError == nil && !model.isStartingRun)
        let calls = fake.args().dropFirst()
        #expect(calls.prefix(2).allSatisfy { $0.hasPrefix("run shape --title ") })
        #expect(Array(calls.suffix(2)) == ["run list --json", "intake list --json -- plotaaaaae"])
    }

    @Test func theBarStopsAtTheFirstFailure() async throws {
        let (model, fake) = try model([("intake_list", 0), ("error_invalid", 2), ("run_list", 0), ("intake_list", 0)])
        await model.showIntake(plot: "plotaaaaae")
        let items = try #require(model.intake?.items).prefix(2)
        let drafts = IntakeContent.batchDrafts(Array(items), kind: .chore, split: false)
        #expect(await model.startIntakeBatch(plot: "plotaaaaae", drafts: drafts, shape: false) == 0)
        #expect(model.runStartError?.isEmpty == false)
        #expect(fake.args().filter { $0.hasPrefix("run start") }.count == 1)
    }

    @Test func theDetailReadsTheRulesAndTheLinearSwitch() async throws {
        let (model, _) = try model([("rule_list", 0), ("linear_updates", 0)])
        #expect(await model.intakeRules(plot: "plotaaaaae").map(\.name) == ["Short README"])
        #expect(await model.linearMovesToInProgress() == true)
    }
}
