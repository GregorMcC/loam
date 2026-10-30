import Foundation
import Testing

@testable import LoamKit

/// TAS-176: the Metrics page reads `loam run metrics`, and Fix this drafts a run that fixes a landed run.
@MainActor
@Suite(.waitLimit) struct MetricsTests {
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    func landedRun() throws -> Run {
        try JSONDecoder().decode(RunLandResult.self, from: Fixtures.data("run_land")).run
    }

    @Test func theMetricsPageReadsEveryPlotThenOne() async throws {
        let (model, fake) = try model([("run_metrics", 0), ("run_metrics", 0)])
        await model.showMetrics()
        #expect(model.page == .metrics && model.metricsPlot == nil)
        #expect(model.metrics?.current.landed == 1 && model.metrics?.current.slowest.first?.title == "Tidy the README")
        await model.showMetrics(plot: "plotaaaaae")
        #expect(model.metricsPlot == "plotaaaaae")
        #expect(fake.args() == ["run metrics --json", "run metrics --plot plotaaaaae --json"])
        #expect(model.sidebar.pageRow == .metrics)
        // A move to a plot closes the page.
        model.activate(plot: "plotaaaaae")
        #expect(model.page == nil)
    }

    @Test func backFromTodayReadsTheMetricsOfThePlotAgain() async throws {
        let (model, fake) = try model([("run_metrics", 0), ("run_metrics", 0)])
        await model.showMetrics(plot: "plotaaaaae")
        model.showToday()
        await model.goBack()
        #expect(model.page == .metrics && model.metricsPlot == "plotaaaaae" && model.metrics != nil)
        #expect(fake.args().filter { $0.hasPrefix("run metrics") } == Array(repeating: "run metrics --plot plotaaaaae --json", count: 2))
    }

    @Test func aFailedReadKeepsTheLastMetrics() async throws {
        let (model, _) = try model([("run_metrics", 0), ("error_invalid", 2)])
        await model.showMetrics()
        await model.reloadMetrics()
        #expect(model.metrics?.current.landed == 1)
    }

    @Test func aFailedFirstReadSaysWhyAndAReadThatWorksClearsIt() async throws {
        let (model, _) = try model([("error_invalid", 2), ("run_metrics", 0)])
        await model.showMetrics()
        #expect(model.metrics == nil && model.metricsError?.isEmpty == false)
        await model.reloadMetrics()
        #expect(model.metrics != nil && model.metricsError == nil)
    }

    @Test func theRunsReadTheMetricsAgainOnlyWhenARunChanged() async throws {
        let (model, fake) = try model([("run_metrics", 0), ("run_list", 0), ("run_metrics", 0), ("run_list", 0)])
        await model.showMetrics()
        await model.reloadRuns()
        await model.reloadRuns()
        #expect(fake.args().filter { $0.hasPrefix("run metrics") }.count == 2)
    }

    @Test func aFixDraftsFromTheIssueAndTheRepoOfTheLandedRun() throws {
        var run = try landedRun()
        run.source = RunSource(kind: "linear", key: "ENG-523", url: "https://linear.app/acme/issue/ENG-523/x")
        var draft = RunDraft(fixing: run)
        #expect(draft.title == "Fix: \(run.title)" && draft.fixes == run.id)
        #expect(draft.link == run.source?.url && draft.ticket == nil && draft.repo == nil)
        run.source = RunSource(kind: "map", key: "map 12", url: "/maps/build/issues/12-plan.md")
        draft = RunDraft(fixing: run)
        #expect(draft.ticket == "/maps/build/issues/12-plan.md" && draft.link == nil)
        run.source = nil
        #expect(RunDraft(fixing: run).link == nil && RunDraft(fixing: run).ticket == nil)
        // A fix of a fix keeps one "Fix:".
        run.title = "Fix: Tidy the README"
        #expect(RunDraft(fixing: run).title == "Fix: Tidy the README")
    }

    @Test func fixThisShapesARunWithFixes() async throws {
        let (model, fake) = try model([("run_shape", 0), ("run_list", 0)])
        let run = try landedRun()
        model.runs = [run]
        await model.fixRun(run.id)
        let shape = try #require(fake.args().first)
        #expect(shape.hasPrefix("run shape --title Fix: Tidy the README "))
        #expect(shape.hasSuffix("--fixes \(run.id) --json -- plotaaaaae"))
        #expect(model.fixError == nil)
    }

    @Test func aFixThatFailsSaysWhyOnTheRunPage() async throws {
        let (model, _) = try model([("error_invalid", 2), ("run_status", 0)])
        let run = try landedRun()
        model.runs = [run]
        await model.fixRun(run.id)
        #expect(model.fixError?.run == run.id && model.fixError?.message.isEmpty == false)
        // The error goes when you open a run page again.
        await model.openRun(run.id)
        #expect(model.fixError == nil)
    }

    @Test func aRunThatHasNotLandedHasNoFix() async throws {
        let (model, fake) = try model([])
        var run = try landedRun()
        run.state = .ready
        model.runs = [run]
        await model.fixRun(run.id)
        #expect(fake.args().isEmpty)
    }

    @Test func timesReadForAPerson() {
        #expect(MetricsWords.duration(0) == "0s" && MetricsWords.duration(45) == "45s")
        #expect(MetricsWords.duration(290) == "5m" && MetricsWords.duration(3600) == "1h")
        #expect(MetricsWords.duration(7843) == "2h 11m" && MetricsWords.duration(86400 * 2 + 3600 * 4) == "2d 4h")
        #expect(MetricsWords.duration(-5) == "0s")
    }

    static func period(landed: Int, lead: Int, stations: [Int], from: String = "2026-10-01T00:00:00Z",
                       to: String = "2026-10-31T00:00:00Z") -> MetricsPeriod {
        func spread(_ median: Int) -> MetricsSpread { MetricsSpread(count: landed, medianSeconds: median, p90Seconds: median) }
        return MetricsPeriod(
            from: from, to: to, landed: landed, firstPass: 0, fixed: 0, leadTime: spread(lead),
            stations: MetricsStations(approve: spread(0), queue: spread(stations[0]), build: spread(stations[1]),
                                      ship: spread(stations[2]), merge: spread(stations[3]), stopped: spread(stations[4])),
            recovery: MetricsRecovery(gate: spread(0), ci: spread(0)),
            rework: MetricsRework(gateTries: 1, ciTries: 0, reviewTries: 0, codeReviewRounds: 2, redrafts: 0, turns: 9),
            notLanded: MetricsNotLanded(stopped: 1, limited: 0, cancelled: 2, startUnknown: 0), slowest: [])
    }

    @Test func theBarSharesTheMediansOfTheStations() throws {
        let p = Self.period(landed: 5, lead: 7800, stations: [0, 1200, 600, 4200, 0])
        let stations = MetricsWords.stations(p)
        #expect(stations.map(\.name) == ["Queue", "Build", "Ship", "Merge", "Stopped"])
        #expect(stations.map(\.share) == [0, 0.2, 0.1, 0.7, 0])
        #expect(MetricsWords.slowestStation(p)?.name == "Merge")
        #expect(MetricsWords.slowestStation(Self.period(landed: 0, lead: 0, stations: [0, 0, 0, 0, 0])) == nil)
        #expect(MetricsWords.stations(Self.period(landed: 1, lead: 0, stations: [0, 0, 0, 0, 0])).allSatisfy { $0.share == 0 })
    }

    @Test func theTrendComparesTheMedianLeadTime() {
        let before = Self.period(landed: 2, lead: 9000, stations: [0, 0, 0, 0, 0],
                                 from: "2026-09-01T00:00:00Z", to: "2026-10-01T00:00:00Z")
        let now = Self.period(landed: 5, lead: 7800, stations: [0, 0, 0, 0, 0])
        #expect(MetricsWords.trend(RunMetrics(current: now, previous: before)) == "20m faster than the 30 days before.")
        #expect(MetricsWords.trend(RunMetrics(current: before, previous: now)) == "20m slower than the 30 days before.")
        var none = before
        none.leadTime = MetricsSpread(count: 0, medianSeconds: 0, p90Seconds: 0)
        #expect(MetricsWords.trend(RunMetrics(current: now, previous: none)) == "No run landed in the 30 days before.")
        #expect(MetricsWords.trend(RunMetrics(current: none, previous: now)) == nil)
        #expect(MetricsWords.perWeek(now) == "1.2 a week")
    }

    @Test func reworkAndNotLandedNameOnlyWhatHappened() {
        let p = Self.period(landed: 5, lead: 0, stations: [0, 0, 0, 0, 0])
        #expect(MetricsWords.rework(p.rework) == "1 gate try \u{00B7} 2 code review rounds")
        #expect(MetricsWords.rework(MetricsRework(gateTries: 0, ciTries: 0, reviewTries: 0, codeReviewRounds: 0, redrafts: 0,
                                                  turns: 4)) == "No rework")
        #expect(MetricsWords.notLanded(p.notLanded) == "1 stopped \u{00B7} 2 cancelled")
        #expect(MetricsWords.share(4, of: 5) == "4 of 5" && MetricsWords.share(0, of: 0) == "None")
        #expect(MetricsWords.approve(MetricsSpread(count: 1, medianSeconds: 180, p90Seconds: 180)) == "3m, 90th 3m (1 drafted run)")
        #expect(MetricsWords.approve(MetricsSpread(count: 0, medianSeconds: 0, p90Seconds: 0)) == "None")
        #expect(MetricsWords.pageTitle(plot: nil) == "Metrics" && MetricsWords.pageTitle(plot: "Runs") == "Metrics \u{00B7} Runs")
    }
}
