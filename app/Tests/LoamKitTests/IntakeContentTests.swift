import Foundation
import Testing

@testable import LoamKit

/// The Intake page: the sources it reads, the source switch, the filter chips and the sort, the Run column, the name
/// of a run worktree, and the bar of the checked rows.
@MainActor
@Suite(.waitLimit, .temporaryFolders) struct IntakeContentTests {
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

    /// TAS-44: the plot menu names each plot, with the count of its intake once the app has read it.
    @Test func thePlotMenuNamesEachPlotWithItsCount() {
        let plots = [PlotSummary(id: "p1", name: "Loam", what: "", createdAt: ""),
                     PlotSummary(id: "p2", name: "Vault", what: "", createdAt: ""),
                     PlotSummary(id: "p3", name: "Quiet", what: "", createdAt: "")]
        let github = [IntakeSource(kind: "github", label: "example/widgets", error: "")]
        let intake = [
            "p1": IntakeList(plotID: "p1", sources: github, items: ["#1", "#2"].map { Self.item("github", key: $0) }),
            "p2": IntakeList(plotID: "p2", sources: [], items: []),
        ]
        let choices = IntakeContent.plotChoices(plots, intake: intake, now: Date())
        #expect(choices.map(\.plotID) == ["p1", "p2", "p3"])
        #expect(choices.map(\.words) == ["Loam \u{00B7} 2 issues", "Vault \u{00B7} None", "Quiet"])
    }

    /// TAS-47: ↓ and ↑ move the selection one row, and stop at each end.
    @Test func theKeysMoveTheSelectionOneRowAndStopAtEachEnd() {
        let rows = ["#1", "#2", "#3"].map { Self.item("github", key: $0) }
        let id = rows.map(\.id)
        #expect(IntakeContent.move(from: id[0], in: rows, by: 1) == id[1])
        #expect(IntakeContent.move(from: id[1], in: rows, by: -1) == id[0])
        #expect(IntakeContent.move(from: id[0], in: rows, by: -1) == id[0])
        #expect(IntakeContent.move(from: id[2], in: rows, by: 1) == id[2])
        // With no selection, or one that the filter hides, the first row is the focused row.
        #expect(IntakeContent.move(from: nil, in: rows, by: 1) == id[1])
        #expect(IntakeContent.move(from: "https://example.com/hidden", in: rows, by: 1) == id[1])
        #expect(IntakeContent.move(from: id[0], in: [], by: 1) == nil)
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

    /// TAS-50: Hide taken is on by default. It hides an item that someone else has or that is in progress, but not an
    /// item that is yours or that has a run.
    @Test func hideTakenHidesTheItemsOfOthersAndTheItemsInProgress() {
        var others = Self.item("linear", key: "ENG-1")
        others.assignee = "Bob Example"
        var started = Self.item("linear", key: "ENG-2", mine: true)
        started.assignee = "Ada Example"
        started.inProgress = true
        var ran = Self.item("linear", key: "ENG-3", run: "run1")
        ran.assignee = "Bob Example"
        ran.inProgress = true
        var mine = Self.item("github", key: "#4", mine: true)
        mine.assignee = "ada, bob"
        let list = Self.list([others, started, ran, mine, Self.item("map", key: "map 5")])
        #expect(IntakeContent.Filter().hideTaken)
        #expect(!IntakeContent.isTaken(started), "an issue of yours in progress is yours")
        #expect(IntakeContent.rows(list, filter: .init()).map(\.key) == ["ENG-2", "#4", "map 5", "ENG-3"])
        #expect(IntakeContent.hideTakenWords(list) == "Hide taken 1")
        // An issue in progress that no one has is taken too.
        var unassigned = Self.item("linear", key: "ENG-6")
        unassigned.inProgress = true
        #expect(IntakeContent.isTaken(unassigned))
        // A list that only Hide taken empties says so.
        var onlyTaken = Self.list([others])
        #expect(IntakeContent.noMatchWords(onlyTaken, filter: .init()).hasPrefix("No item matches. Hide taken hides"))
        onlyTaken.items = []
        #expect(IntakeContent.hideTakenWords(onlyTaken) == "Hide taken")
        var all = IntakeContent.Filter()
        all.hideTaken = false
        #expect(IntakeContent.rows(list, filter: all).map(\.key) == ["ENG-1", "ENG-2", "#4", "map 5", "ENG-3"])
        #expect(IntakeContent.noMatchWords(list, filter: all) == "No item matches.")
    }

    /// TAS-51: the Milestone menu has All, the milestones in the order of the project, then No milestone, and a choice
    /// keeps only its items. A list with no milestone has no menu.
    @Test func theMilestoneMenuKeepsTheProjectOrderAndFiltersTheRows() {
        func item(_ key: String, _ milestone: String, _ order: Double) -> IntakeItem {
            var item = Self.item("linear", key: key)
            item.milestone = milestone
            item.milestoneOrder = order
            return item
        }
        let list = Self.list([item("ENG-1", "Beta", 2), item("ENG-2", "Alpha", 1), item("ENG-3", "", 0),
                              item("ENG-4", "Beta", 2), item("ENG-5", "Aardvark", 2)])
        let choices = IntakeContent.milestoneChoices(list)
        #expect(choices.map(\.words) == ["All milestones", "Alpha", "Aardvark", "Beta", "No milestone"])
        #expect(choices.map(\.milestone) == [nil, "Alpha", "Aardvark", "Beta", ""])
        func keys(_ milestone: String?) -> [String] {
            var filter = IntakeContent.Filter()
            filter.milestone = milestone
            return IntakeContent.rows(list, filter: filter).map(\.key)
        }
        #expect(keys(nil) == ["ENG-1", "ENG-2", "ENG-3", "ENG-4", "ENG-5"])
        #expect(keys("Beta") == ["ENG-1", "ENG-4"])
        #expect(keys("") == ["ENG-3"])
        // A choice that the list no longer has keeps every item, and the menu says All.
        #expect(keys("Gamma") == ["ENG-1", "ENG-2", "ENG-3", "ENG-4", "ENG-5"])
        var gone = IntakeContent.Filter()
        gone.milestone = "Gamma"
        #expect(IntakeContent.activeMilestone(list, filter: gone) == nil)
        // A name in two projects takes its first place.
        let twice = Self.list([item("ENG-6", "Beta", 7), item("ENG-7", "Beta", 0.5), item("ENG-8", "Alpha", 1)])
        #expect(IntakeContent.milestoneChoices(twice).map(\.words) == ["All milestones", "Beta", "Alpha", "No milestone"])
        #expect(IntakeContent.milestoneWords(nil) == "Milestone")
        #expect(IntakeContent.milestoneWords("") == "No milestone")
        #expect(IntakeContent.milestoneWords("Beta") == "Beta")
        #expect(IntakeContent.milestoneChoices(Self.list([Self.item("github", key: "#1")])).isEmpty)
    }

    @Test func theDetailSaysTheAssigneeAndTheMilestone() {
        var item = Self.item("linear", key: "ENG-1")
        #expect(IntakeContent.detailFacts(item) == "")
        item.assignee = "Bob Example"
        #expect(IntakeContent.detailFacts(item) == "Assigned to Bob Example")
        item.milestone = "Alpha"
        #expect(IntakeContent.detailFacts(item) == "Assigned to Bob Example \u{00B7} Milestone Alpha")
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
