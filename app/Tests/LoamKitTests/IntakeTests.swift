import Foundation
import Testing

@testable import LoamKit

/// Ticket 204: the Intake page lists the open issues and map tickets of a plot, and starts a run from one.
@MainActor
@Suite(.waitLimit) struct IntakeTests {
    /// The intake fixture is for the plot plotaaaaae, as the run fixtures are.
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    static func item(_ source: String, url: String) -> IntakeItem {
        IntakeItem(source: source, key: "k", title: "Fix the login form", status: "Open", priority: "", labels: [], url: url,
                   updatedAt: "", runID: "")
    }

    @Test func aDraftStartsFromTheIssueOrTheTicketOfItsItem() {
        let issue = RunDraft(item: Self.item("github", url: "https://github.com/example/widgets/issues/57"))
        #expect(issue.title == "Fix the login form")
        #expect(issue.link == "https://github.com/example/widgets/issues/57" && issue.ticket == nil)
        let ticket = RunDraft(item: Self.item("map", url: "/maps/build/issues/12-plan.md"))
        #expect(ticket.ticket == "/maps/build/issues/12-plan.md" && ticket.link == nil)
        #expect(ticket.maxTries == 3 && ticket.checks.isEmpty && !ticket.approveSetup)
    }

    @Test func intakeReadsTheListOfThePlot() async throws {
        let (model, fake) = try model([("intake_list", 0)])
        await model.showIntake(plot: "plotaaaaae")
        #expect(model.page == .intake("plotaaaaae"))
        #expect(model.intake?.items.map(\.key) == ["ENG-523", "ENG-525", "#61", "#57", "map 12", "map 13"])
        #expect(model.intake?.items[0].priority == "High")
        #expect(model.intake?.items[3].runID == "runraaaaab")
        #expect(fake.args() == ["intake list --json -- plotaaaaae"])
        // A move to a plot closes the page.
        model.activate(plot: "plotaaaaae")
        #expect(model.page == nil)
    }

    /// TAS-44: the plot menu of the page, and the Intake column of Today, show the intake of another plot. The active plot
    /// of the window stays.
    @Test func anotherPlotsIntakeKeepsTheActivePlot() async throws {
        let (model, fake) = try model([("intake_list", 0), ("intake_list", 0)])
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z"),
                     PlotSummary(id: "plotbbbbbb", name: "Reports", what: "", createdAt: "2026-01-01T00:00:00Z")])
        model.activate(plot: "plotaaaaae")
        await model.showIntake(plot: "plotaaaaae")
        await model.showIntake(plot: "plotbbbbbb")
        #expect(model.page == .intake("plotbbbbbb"))
        #expect(model.workspace.activePlotID == "plotaaaaae")
        #expect(fake.args() == ["intake list --json -- plotaaaaae", "intake list --json -- plotbbbbbb"])
    }

    @Test func aStartedRunOpensItsPage() async throws {
        let (model, fake) = try model([("intake_list", 0), ("run_start", 0), ("run_list", 0), ("run_status", 0)])
        await model.showIntake(plot: "plotaaaaae")
        var draft = RunDraft(item: try #require(model.intake?.items[4]))
        draft.goal = "Show the plan."
        draft.checks = [RunCheck(name: "Tests", command: "go test ./...")]
        draft.approveSetup = true
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft))
        #expect(model.page == .run("runraaaaab"))
        #expect(model.runStartError == nil)
        let start = try #require(fake.args().dropFirst().first)
        #expect(start == "run start --title Run page: show the plan --goal Show the plan. --check Tests=go test ./... "
            + "--max-tries 3 --ticket /tmp/loam-contract/build/issues/12-run-page-plan.md --approve-setup --json -- plotaaaaae")
        #expect(Array(fake.args().suffix(2)) == ["run list --json", "run status --json -- runraaaaab"])
    }

    @Test func aRunThatDoesNotStartKeepsThePageAndSaysWhy() async throws {
        let (model, _) = try model([("intake_list", 0), ("error_invalid", 2)])
        await model.showIntake(plot: "plotaaaaae")
        let draft = RunDraft(item: try #require(model.intake?.items[0]))
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft) == false)
        #expect(model.page == .intake("plotaaaaae"))
        #expect(model.runStartError?.isEmpty == false)
    }

    // MARK: Base

    static func check(defaultBase: String, bases: [String]) -> WorktreeCheck {
        WorktreeCheck(name: "loam-run-base", folder: "widgets-loam-run-base", validName: true, nameError: nil,
                      worktreeExists: false, branchExists: false, defaultBase: defaultBase, bases: bases, seedLine: nil)
    }

    /// TAS-21: with an origin, the picker starts on the default branch of origin, which the core takes with no base.
    @Test func theBasesStartOnTheDefaultBranchOfOrigin() {
        let bases = RunBases(plot: "p", check: Self.check(defaultBase: "origin/main", bases: ["origin/main", "origin/next", "main"]),
                             branch: "main")
        #expect(bases.items.map(\.title) == ["origin/main", "origin/next", "main"])
        #expect(bases.items.map(\.value) == [nil, "origin/next", "main"])
        #expect(bases.first == nil)
        // An origin whose default branch Loam has not fetched yet.
        let unknown = RunBases(plot: "p", check: Self.check(defaultBase: "", bases: ["origin/next", "main"]), branch: "main")
        #expect(unknown.items.first == RunBases.Item(title: NewWorktreeContent.originDefault, value: nil) && unknown.first == nil)
    }

    /// TAS-21: a repo with no origin has no default branch of origin, so the picker starts on the branch of the main
    /// checkout, and the run gets it as its base.
    @Test func withNoOriginTheBasesStartOnTheBranchOfTheCheckout() {
        let bases = RunBases(plot: "p", check: Self.check(defaultBase: "", bases: ["feature", "trunk", "old"]), branch: "trunk")
        #expect(bases.items.map(\.title) == ["trunk", "feature", "old"])
        #expect(bases.items.map(\.value) == ["trunk", "feature", "old"])
        #expect(bases.first == "trunk")
        // A detached checkout: the newest branch.
        #expect(RunBases(plot: "p", check: Self.check(defaultBase: "", bases: ["feature", "trunk"]), branch: nil).first == "feature")
    }

    @Test func theBasesComeFromADryRunOfTheMainRepo() async throws {
        let (model, fake) = try model([("worktree_new_dry_run", 0)])
        await model.readRunBases(plot: "plotaaaaae", repo: "repoaaaaag", branch: "main")
        #expect(fake.args() == ["worktree new --dry-run --json -- plotaaaaae repoaaaaag loam-run-base"])
        #expect(model.runBases?.plot == "plotaaaaae" && model.runBases?.items.map(\.title) == ["origin/main", "main"])
    }

    @Test func aBaseGoesToTheCore() async throws {
        let (model, fake) = try model([("run_start", 0), ("run_list", 0), ("run_status", 0), ("run_shape", 0)])
        var draft = RunDraft(item: Self.item("map", url: "/maps/12.md"))
        draft.base = "trunk"
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft))
        #expect(fake.args().first == "run start --title Fix the login form --goal  --max-tries 3 --base trunk --ticket /maps/12.md "
            + "--json -- plotaaaaae")
        _ = await model.shapeRun(plot: "plotaaaaae", draft: draft)
        #expect(fake.args().contains { $0.hasPrefix("run shape --title Fix the login form --max-tries 3 --base trunk --ticket") })
    }

    /// The model and the effort that you pick go to the core. Default sends neither, so the plot default applies.
    @Test func aModelAndAnEffortGoToTheCore() async throws {
        let (model, fake) = try model([("run_start", 0), ("run_list", 0), ("run_status", 0), ("run_shape", 0)])
        var draft = RunDraft(item: Self.item("map", url: "/maps/12.md"))
        draft.model = "opus"
        draft.effort = "high"
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft))
        #expect(fake.args().first?.contains("--ticket /maps/12.md --model opus --effort high --json") == true)
        draft.model = ""
        _ = await model.shapeRun(plot: "plotaaaaae", draft: draft)
        #expect(fake.args().contains { $0.contains("--ticket /maps/12.md --effort high --json") && $0.hasPrefix("run shape") })
    }

    /// The plot defaults: read, then set. "" clears one.
    @Test func thePlotDefaultsAreReadAndSet() async throws {
        let (model, fake) = try model([("run_defaults_get", 0), ("run_defaults_set", 0)])
        await model.readRunDefaults(plot: "plotaaaaae")
        #expect(model.runDefaults == RunDefaults(plotID: "plotaaaaae", model: "", effort: ""))
        await model.setRunDefaults(plot: "plotaaaaae", model: "opus", effort: "high")
        #expect(fake.args().last == "run defaults --model opus --effort high --json -- plotaaaaae")
        #expect(model.runDefaults?.model == "opus" && model.runDefaults?.effort == "high" && model.runDefaultsError == nil)
    }

    @Test func theDefaultChoiceSaysWhatTheDefaultIs() {
        #expect(RunChoices.defaultTitle("opus", in: RunChoices.models) == "Default (Opus)")
        #expect(RunChoices.defaultTitle("", in: RunChoices.efforts) == "Default")
        #expect(RunChoices.defaultTitle("xhigh", in: RunChoices.efforts) == "Default (Extra high)")
    }

    // MARK: Repo and split (TAS-37)

    /// The Repo picker lists the main repo first, by folder name. With two repos or more, Claude can split the issue.
    @Test func theRepoPickerListsTheReposAndTheSplit() {
        let one = [RepoCheckout(id: "repoa", path: "/src/app", isMain: true)]
        #expect(RunChoices.repos(one).map(\.title) == ["app"])
        let two = [RepoCheckout(id: "repob", path: "/src/site", isMain: false), RepoCheckout(id: "repoa", path: "/src/app", isMain: true)]
        #expect(RunChoices.repos(two).map(\.value) == ["repoa", "repob", RunChoices.split])
    }

    /// A GitHub issue starts on its own repo. The split choice clears the repo, and a repo choice clears the split.
    @Test func theRepoChoiceSetsTheRepoOrTheSplit() {
        var item = Self.item("github", url: "https://github.com/example/site/issues/3")
        item.repo = "repob"
        var draft = RunDraft(item: item)
        #expect(draft.repo == "repob" && !draft.split && draft.repoChoice == "repob")
        draft.repoChoice = RunChoices.split
        #expect(draft.split && draft.repo == nil)
        draft.repoChoice = "repoa"
        #expect(!draft.split && draft.repo == "repoa")
        #expect(RunDraft(item: Self.item("linear", url: "https://example.com/ENG-1")).repo == nil)
    }

    @Test func aRepoOrASplitGoesToTheCore() async throws {
        let (model, fake) = try model([("run_start", 0), ("run_list", 0), ("run_status", 0), ("run_shape_split", 0)])
        var draft = RunDraft(item: Self.item("map", url: "/maps/12.md"))
        draft.repo = "repob"
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft))
        #expect(fake.args().first == "run start --title Fix the login form --goal  --max-tries 3 --repo repob --ticket /maps/12.md "
            + "--json -- plotaaaaae")
        draft.repoChoice = RunChoices.split
        _ = await model.shapeRun(plot: "plotaaaaae", draft: draft)
        let shape = try #require(fake.args().first { $0.hasPrefix("run shape") })
        #expect(shape.contains("--split") && !shape.contains("--repo"))
    }

    /// The runs of a split share a group, and each one links to the others.
    @Test func theRunsOfASplitLinkToEachOther() throws {
        let result = try JSONDecoder().decode(RunResult.self, from: Fixtures.data("run_shape_split"))
        let runs = try #require(result.runs)
        #expect(runs.count == 2 && Set(runs.map(\.groupID)) == [result.run.groupID])
        let model = AppModel(client: try FakeLoam([]).client())
        model.runs = runs
        #expect(model.groupRuns(of: runs[0]).map(\.id) == [runs[1].id])
        var alone = runs[0]
        alone.groupID = ""
        #expect(model.groupRuns(of: alone).isEmpty)
    }
}
