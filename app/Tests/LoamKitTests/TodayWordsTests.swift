import Foundation
import Testing
@testable import LoamKit

/// The text of Today around the tiles and the line: the header, While you were away, the limits, the sidebar card,
/// and the action bar of Today and of the Intake page.
@Suite struct TodayWordsTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// A Wednesday.
    static let now = ChangeRules.date("2026-10-28T18:00:00Z")!

    static func run(_ id: String, _ state: RunState) -> Run {
        TodayContentTests.run(id, plot: "p1", state)
    }

    @Test func theCaptionSaysTheDayAndTheRunsThatWork() {
        let limits = RunLimits(atATime: 3, maxTurns: 40, holdAt: 80)
        let runs = [Self.run("a", .running), Self.run("b", .starting), Self.run("c", .queued), Self.run("d", .shipping)]
        #expect(TodayWords.caption(runs: runs, limits: limits, now: Self.now, timeZone: Self.utc)
            == "Wednesday 28 October \u{00B7} 2 of 3 running \u{00B7} 1 waits for a slot")
        // No queue part when none waits, and no limit before the limits are read.
        #expect(TodayWords.caption(runs: [Self.run("a", .startUnknown)], limits: nil, now: Self.now, timeZone: Self.utc)
            == "Wednesday 28 October \u{00B7} 1 running")
        let two = [Self.run("c", .queued), Self.run("e", .queued)]
        #expect(TodayWords.caption(runs: two, limits: limits, now: Self.now, timeZone: Self.utc).hasSuffix("2 wait for a slot"))
    }

    @Test func theDeskCaptionCountsTheDecisions() {
        #expect(TodayWords.deskCaption(count: 0) == "Nothing needs a decision from you.")
        #expect(TodayWords.deskCaption(count: 1) == "1 thing needs a decision from you.")
        #expect(TodayWords.deskCaption(count: 5) == "5 things need a decision from you. The desk shows them one at a time.")
    }

    @Test func awayShowsTheNewestEightEventsWithTheirRun() {
        let event = { (n: Int, kind: String, detail: String) in
            RunFeedEvent(runID: "r\(n)", plotID: "p1", runTitle: "Run \(n)", at: "2026-10-28T0\(n % 10):30:00Z",
                         kind: kind, detail: detail)
        }
        var events = [event(6, "state", "stopped"), event(5, "ship", "Opened #12"), event(4, "try", "")]
        events += (0..<7).map { event($0, "state", "running") }
        let rows = TodayWords.away(events, now: Self.now, timeZone: Self.utc)
        #expect(rows.count == 8)
        #expect(rows[0] == TodayWords.AwayRow(id: 0, runID: "r6", time: "06:30", title: "Run 6", detail: "Stopped", stopped: true))
        #expect(rows[1].detail == "Opened #12" && !rows[1].stopped)
        #expect(rows[2].detail == "A try failed")
        let since = ChangeRules.date("2026-10-27T23:10:00Z")!
        #expect(TodayWords.awayCaption(since: since, empty: false, now: Self.now, timeZone: Self.utc) == "Since 27 Oct, 23:10")
        #expect(TodayWords.awayCaption(since: Self.now.addingTimeInterval(-3600), empty: true, now: Self.now, timeZone: Self.utc)
            == "Nothing happened since 17:00")
    }

    @Test func theLimitsCardSaysEachLimit() {
        #expect(TodayWords.limits(RunLimits(atATime: 3, maxTurns: 40, holdAt: 80), tries: 3).map(\.value)
            == ["3 runs", "40 turns \u{00B7} 3 tries", "80% of the week", "Only by you"])
        #expect(TodayWords.limits(RunLimits(atATime: 1, maxTurns: 0, holdAt: 0), tries: 1).map(\.value)
            == ["1 run", "No turn limit \u{00B7} 1 try", "Off", "Only by you"])
        #expect(TodayWords.limits(RunLimits(atATime: 1, maxTurns: 0, holdAt: 0), tries: 1).map(\.label)
            == ["At a time", "Each run", "Hold new runs at", "Merges"])
    }

    @Test func theRunsCardSaysTheSlotsTheUsageAndTheNextTimes() throws {
        let usage = Usage(fiveHour: nil, sevenDay: UsageWindow(utilization: 0.414, resetsAt: "2026-11-02T09:00:00Z"),
                          readAt: "2026-10-28T17:00:00Z")
        var recurring = try JSONDecoder().decode(RecurringList.self, from: Fixtures.data("recurring_list")).recurring
        recurring[0].nextAt = "2026-10-28T22:00:00Z"
        recurring[1].nextAt = "2026-10-29T06:30:00Z"
        let card = TodayWords.runsCard(runs: [Self.run("a", .running), Self.run("b", .ready)],
                                       limits: RunLimits(atATime: 3, maxTurns: 40, holdAt: 80), usage: usage,
                                       recurring: recurring, now: Self.now, timeZone: Self.utc)
        #expect(card == TodayWords.RunsCard(running: "1 of 3", usage: "41%", usageFraction: 0.414,
                                            footer: "Next recurring run 22:00 \u{00B7} Resets Monday 09:00"))
        // A week that has reset is not known, and with no recurring run there is no footer.
        let old = Usage(fiveHour: nil, sevenDay: UsageWindow(utilization: 0.9, resetsAt: "2026-10-28T09:00:00Z"), readAt: nil)
        let bare = TodayWords.runsCard(runs: [], limits: nil, usage: old, recurring: [], now: Self.now, timeZone: Self.utc)
        #expect(bare == TodayWords.RunsCard(running: "0", usage: nil, usageFraction: 0, footer: nil))
    }

    @Test func theSourcesCardSaysWhenEachSourceWasRead() throws {
        var list = try JSONDecoder().decode(IntakeList.self, from: Fixtures.data("intake_list"))
        list.sources.append(IntakeSource(kind: "github", label: "example/docs", error: "gh is missing"))
        let reads = [
            TodayWords.sourceKey(list.sources[0]): Self.now.addingTimeInterval(-120),
            TodayWords.sourceKey(list.sources[1]): Self.now.addingTimeInterval(-10),
            TodayWords.sourceKey(list.sources[2]): Self.now.addingTimeInterval(-3 * 3600),
        ]
        let rows = TodayWords.sourcesCard(list, reads: reads, now: Self.now)
        #expect(rows.map(\.label) == ["Linear", "example/widgets", "Map", "example/docs"])
        #expect(rows.map(\.value) == ["Read 2 min ago", "Read just now", "Read 3 h ago", "Could not read"])
        #expect(TodayWords.ago(3 * 24 * 3600) == "3 d ago")
    }

    @Test func todayAndIntakeHaveTheirOwnBar() throws {
        let today = try #require(PageBar(page: .today, plotName: ""))
        #expect(today.title == "Today" && today.detail == "All plots")
        #expect(today.items.map(\.title) == ["Open the desk", "Start a run"])
        #expect(today.items.map(\.keys) == [["\u{2318}", "\u{21A9}"], ["\u{2318}", "R"]])
        #expect(today.items.map(\.action) == [.openDesk, .startRun])
        let intake = try #require(PageBar(page: .intake("p1"), plotName: "Loam redesign"))
        #expect(intake.title == "Intake" && intake.detail == "Loam redesign")
        // The Intake page handles its keys, so the bar only names them.
        #expect(intake.items.map(\.title) == ["Select", "Shape selected"] && intake.items.allSatisfy { $0.action == nil })
        #expect(PageBar(page: .desk, plotName: "") == nil && PageBar(page: nil, plotName: "") == nil)
    }
}

/// What Today reads from the core, and when it reads it again.
@MainActor
@Suite(.waitLimit) struct TodayReadTests {
    static let plot = PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")

    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([Self.plot])
        return (model, fake)
    }

    @Test func todayReadsTheEventsTheLimitsTheRecurringRunsAndTheIntake() async throws {
        let (model, fake) = try model([("run_events", 0), ("run_limits_get", 0), ("recurring_list", 0), ("intake_list", 0),
                                       ("run_events", 0), ("run_limits_get", 0), ("recurring_list", 0)])
        var clock = ChangeRules.date("2026-10-28T18:00:00Z")!
        model.now = { clock }
        await model.readToday()
        #expect(model.todayData.awayEvents.count == 2 && model.todayData.awaySince == clock.addingTimeInterval(-24 * 3600))
        #expect(model.todayData.limits?.atATime == 3 && model.todayData.recurring.count == 2)
        #expect(model.intakeCount == 6 && model.today.line.first?.intake?.count == "6 items")
        #expect(model.todayData.sourceReads["plotaaaaae"]?.count == 3)
        #expect(fake.args() == ["run events --since 2026-10-27T18:00:00Z --json", "run limits --json", "recurring list --json",
                                "intake list --json -- plotaaaaae"])

        // Within 5 minutes the intake comes from the cache.
        clock.addTimeInterval(4 * 60)
        await model.readToday()
        #expect(fake.args().count == 7 && !fake.args()[4...].contains { $0.hasPrefix("intake") })
        // A plot that is gone does not count.
        model.apply([])
        #expect(model.intakeCount == 0)
    }

    /// The desk and a run page open from Today. A move to them keeps the time of away, and a move out of all three
    /// moves it.
    @Test func theDeskAndARunPageDoNotLeaveToday() throws {
        let (model, _) = try model([])
        let clock = ChangeRules.date("2026-10-28T18:00:00Z")!
        model.now = { clock }
        model.page = .today
        model.page = .desk
        model.page = .run("runraaaaab")
        #expect(model.todayData.leftAt == nil)
        model.page = .intake("plotaaaaae")
        #expect(model.todayData.leftAt == clock)
    }

    @Test func leavingTodayMovesTheTimeOfAway() async throws {
        let (model, fake) = try model([("run_list", 0), ("run_list", 0), ("run_events", 0)])
        let clock = ChangeRules.date("2026-10-28T18:00:00Z")!
        model.now = { clock }
        model.showToday()
        model.activate(plot: "plotaaaaae")
        #expect(model.page == nil && model.todayData.leftAt == clock)
        // The change feed reads the events again only while Today shows.
        await model.reloadRuns()
        model.showToday()
        await model.reloadRuns()
        #expect(fake.args() == ["run list --json", "run list --json", "run events --since 2026-10-28T18:00:00Z --json"])
    }

    /// A refresh of the usage costs a Claude call: Today asks only when the usage is 30 minutes old, and at most once
    /// in 30 minutes.
    @Test func theUsageRefreshesAtMostOnceInThirtyMinutes() async throws {
        let (model, fake) = try model([("usage_none", 0), ("usage_refresh", 1), ("usage_none", 0), ("usage_none", 0),
                                       ("usage_refresh", 0)])
        var clock = ChangeRules.date("2026-01-01T00:10:00Z")!
        model.now = { clock }
        await model.readUsage()
        // The refresh failed, so the usage stays unknown, and the next read asks no refresh.
        #expect(model.todayData.usage?.sevenDay == nil)
        await model.readUsage()
        #expect(fake.args() == ["usage --json", "usage --refresh --json", "usage --json"])
        clock.addTimeInterval(31 * 60)
        await model.readUsage()
        #expect(fake.args().suffix(2) == ["usage --json", "usage --refresh --json"])
        #expect(model.todayData.usage?.sevenDay?.utilization == 0.41)
    }

    @Test func startARunOpensTheIntakeOfTheActivePlot() throws {
        let (model, _) = try model([("run_list", 0)])
        model.activate(plot: "plotaaaaae")
        #expect(model.startRunPlot == "plotaaaaae")
    }
}
