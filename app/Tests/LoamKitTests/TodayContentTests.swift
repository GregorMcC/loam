import Foundation
import Testing
@testable import LoamKit

/// Ticket 203: Today groups the runs for the desk tiles and the line. Ticket 206 adds Ship, where a run waits for its
/// PR and CI, and Land, where a ready run waits for you.
@Suite struct TodayContentTests {
    static let now = ChangeRules.date("2026-10-27T18:00:00Z")!

    static func run(_ id: String, plot: String, _ state: RunState, updated: String = "2026-10-27T17:00:00Z",
                    title: String? = nil) -> Run {
        Run(id: id, plotID: plot, worktreeID: "", folder: "/w/\(id)", title: title ?? "Run \(id)", goal: "", doneWhen: [],
            state: state, tries: 0, maxTries: 3, source: nil, sessionID: "", note: "",
            createdAt: "2026-10-27T09:00:00Z", updatedAt: updated)
    }

    static let plots = [
        PlotSummary(id: "p1", name: "Loam", what: "", createdAt: "2026-10-01T09:00:00Z"),
        PlotSummary(id: "p2", name: "Reporting", what: "", createdAt: "2026-10-01T09:00:00Z"),
        PlotSummary(id: "p3", name: "Quiet", what: "", createdAt: "2026-10-01T09:00:00Z"),
    ]

    @Test func tilesCountWhatWaitsForYou() {
        let runs = [
            Self.run("a", plot: "p1", .shaping), Self.run("b", plot: "p1", .stopped), Self.run("c", plot: "p2", .limited),
            Self.run("d", plot: "p2", .ready), Self.run("e", plot: "p1", .running), Self.run("f", plot: "p1", .shipping),
        ]
        let today = TodayContent(runs: runs, plots: Self.plots, now: Self.now)
        // A run that ships waits for CI, not for you, so no tile counts it.
        #expect(today.tiles.map(\.station) == [.shape, .land, .stopped])
        #expect(today.tiles.map(\.count) == [1, 1, 2])
        #expect(today.needsYouCount == 3)
        #expect(Set(today.needsYou.map(\.id)) == ["a", "b", "c"])
    }

    /// A tile names its first 2 runs, the longest wait first, says how long they wait, and adds one line about them.
    @Test func aTileNamesItsRunsAndHowLongTheyWait() throws {
        var older = Self.run("a", plot: "p1", .stopped, updated: "2026-10-27T15:40:00Z", title: "Copy the last command output")
        older.pr = RunPR(number: 144, url: "https://github.com/example/widgets/pull/144")
        older.note = "CI failed 3 times on lint / swiftformat\nThe log follows."
        var newer = Self.run("b", plot: "p2", .stopped, updated: "2026-10-27T16:00:00Z", title: "Tidy the charts")
        newer.source = RunSource(kind: "linear", key: "WEB-31", url: "https://linear.app/acme/issue/WEB-31")
        let third = Self.run("c", plot: "p2", .limited, updated: "2026-10-27T17:00:00Z")
        let utc = try #require(TimeZone(identifier: "UTC"))
        let tile = TodayContent(runs: [third, newer, older], plots: Self.plots, now: Self.now, timeZone: utc).tiles[2]
        #expect(tile.count == 3)
        #expect(tile.runs.map(\.words) == ["Copy the last command output \u{00B7} #144", "Tidy the charts \u{00B7} WEB-31"])
        #expect(tile.age == "since 15:40")
        // The first line of the note of the longest wait, in rust.
        #expect(tile.context == "CI failed 3 times on lint / swiftformat" && tile.contextStops)
    }

    @Test func theShapeTileSaysWhichRecurringRunShapedARun() throws {
        var run = Self.run("a", plot: "p1", .shaping, updated: "2026-10-27T16:00:00Z")
        run.source = RunSource(kind: "recurring", key: "recuaaaaab", url: "")
        let recurring = try JSONDecoder().decode(RecurringList.self, from: Fixtures.data("recurring_list")).recurring
        let tile = TodayContent(runs: [run], plots: Self.plots, now: Self.now, recurring: recurring).tiles[0]
        #expect(tile.age == "oldest 2 h")
        #expect(tile.context == "Shaped by the 02:00 recurring run" && !tile.contextStops)
        // The key of a recurring source is an ID, so the tile names the title alone.
        #expect(tile.runs.map(\.words) == ["Run a"])
    }

    @Test func theLandTileSaysWhatPassed() {
        var withPR = Self.run("a", plot: "p1", .ready)
        withPR.pr = RunPR(number: 147, url: "https://github.com/example/widgets/pull/147")
        #expect(TodayContent(runs: [withPR], plots: Self.plots, now: Self.now).tiles[1].context == "All checks and CI passed")
        let noPR = Self.run("b", plot: "p1", .ready)
        #expect(TodayContent(runs: [withPR, noPR], plots: Self.plots, now: Self.now).tiles[1].context == "All checks passed")
        // An empty tile names no run and has no age.
        let empty = TodayContent(runs: [], plots: Self.plots, now: Self.now).tiles[1]
        #expect(empty.runs.isEmpty && empty.age == nil && empty.context == nil)
    }

    @Test func waitsReadAsMinutesHoursOrDays() {
        #expect(TodayContent.duration(20) == "1 min")
        #expect(TodayContent.duration(25 * 60) == "25 min")
        #expect(TodayContent.duration(3 * 3600 + 59 * 60) == "3 h")
        #expect(TodayContent.duration(50 * 3600) == "2 d")
    }

    @Test func theLineHasAChipForEachRunAtItsStation() {
        let runs = [
            Self.run("a", plot: "p1", .shaping), Self.run("b", plot: "p1", .running), Self.run("c", plot: "p1", .startUnknown),
            Self.run("d", plot: "p2", .ready), Self.run("h", plot: "p2", .shipping),
            Self.run("e", plot: "p2", .landed, updated: "2026-10-25T10:00:00Z"),
            Self.run("f", plot: "p2", .landed, updated: "2026-10-10T10:00:00Z"),  // over a week ago
            Self.run("g", plot: "gone", .running),  // a plot that is not in the list
        ]
        let line = TodayContent(runs: runs, plots: Self.plots, now: Self.now).line
        #expect(line.map(\.plotName) == ["Loam", "Reporting"])
        #expect(line[0].chips.mapValues { $0.map(\.runID) } == [.shape: ["a"], .run: ["b", "c"]])
        #expect(line[1].chips.mapValues { $0.map(\.runID) } == [.ship: ["h"], .land: ["d"]])
        #expect(line.map(\.landed) == [0, 1])
        #expect(TodayContent.lineStations == [.shape, .run, .ship, .land])
    }

    /// A stopped run sits where it stopped: Ship when it has a PR, else Run.
    @Test func aStoppedRunSitsWhereItStopped() {
        var shipped = Self.run("a", plot: "p1", .stopped)
        shipped.pr = RunPR(number: 144, url: "https://github.com/example/widgets/pull/144")
        let gate = Self.run("b", plot: "p1", .limited)
        let row = TodayContent(runs: [shipped, gate], plots: Self.plots, now: Self.now).line[0]
        #expect(row.chips[.ship]?.map(\.runID) == ["a"] && row.chips[.run]?.map(\.runID) == ["b"])
        #expect(row.chips[.ship]?.first?.state == "Stopped" && row.chips[.ship]?.first?.stopped == true)
        #expect(row.chips[.run]?.first?.state == "Usage limit" && row.chips[.run]?.first?.mark == .needsYou)
    }

    @Test func aChipHasAShortIDAndAShortState() {
        func chip(_ state: RunState, tries: Int = 0, turns: Int = 0, pr: Int? = nil, source: RunSource? = nil) -> TodayContent.Chip {
            var run = Self.run("a", plot: "p1", state, title: "Window size")
            run.tries = tries
            run.turns = turns
            run.pr = pr.map { RunPR(number: $0, url: "") }
            run.source = source
            return TodayContent.chip(run)
        }
        let linear = RunSource(kind: "linear", key: "ENG-514", url: "")
        #expect(chip(.running, tries: 1, source: linear).state == "Try 2 of 3" && chip(.running, source: linear).key == "ENG-514")
        #expect(chip(.running, turns: 12).state == "Turn 12" && chip(.running).state == "Running")
        #expect(chip(.shipping, tries: 1, pr: 146).state == "CI, try 2 of 3" && chip(.shipping, pr: 146).state == "Waits for CI")
        #expect(chip(.shipping).state == "Shipping" && chip(.shipping, pr: 146).key == "#146")
        #expect(chip(.ready, pr: 147).state == "Ready" && chip(.ready).mark == .doneUnread)
        #expect(chip(.shaping).state == "Window size" && chip(.shaping).mark == .needsYou)
        let queued = chip(.queued)
        #expect(queued.state == "Waits for a slot" && queued.waits && queued.mark == .none)
        // A GitHub issue key loses its repo, and a recurring source has no key.
        #expect(chip(.running, source: RunSource(kind: "github", key: "example/widgets#57", url: "")).key == "#57")
        #expect(chip(.running, source: RunSource(kind: "recurring", key: "recuaaaaab", url: "")).key == "")
    }

    /// A plot with an intake source is on the line with no run. Its Intake cell counts the items, and the new ones.
    @Test func theLineShowsTheIntakeOfEachPlot() throws {
        var list = try JSONDecoder().decode(IntakeList.self, from: Fixtures.data("intake_list"))
        list.plotID = "p3"
        list.items[0].createdAt = "2026-10-27T09:00:00Z"
        let row = try #require(TodayContent(runs: [], plots: Self.plots, now: Self.now, intake: ["p3": list],
                                            repoNames: ["p3": "widgets"]).line.first)
        #expect(row.plotID == "p3" && row.chips.isEmpty)
        #expect(row.caption == "ENG \u{00B7} widgets")
        #expect(row.intake == TodayContent.IntakeCell(count: "6 items", caption: "1 new since yesterday"))

        let tickets = IntakeList(plotID: "p3", sources: [IntakeSource(kind: "map", label: "Build map", error: "")],
                                 items: [list.items[4]])
        #expect(TodayContent.intakeCell(tickets, now: Self.now) == .init(count: "1 item", caption: "from the plot's map"))
        #expect(TodayContent.plotCaption(intake: tickets, repo: "widgets") == "No Linear link")
        let issues = IntakeList(plotID: "p3", sources: list.sources, items: Array(list.items[0...1]))
        #expect(TodayContent.intakeCell(issues, now: Self.now).count == "2 issues")
        let none = IntakeList(plotID: "p3", sources: [], items: [])
        #expect(TodayContent.intakeCell(none, now: Self.now).none)
        // A plot with no source and no run is not on the line.
        #expect(TodayContent(runs: [], plots: Self.plots, now: Self.now, intake: ["p3": none]).line.isEmpty)
    }

    /// A run that finds no free slot waits in Queued, at the Run station, and the note says why.
    @Test func aRunWithNoFreeSlotWaitsForASlot() throws {
        let run = try JSONDecoder().decode(RunStartResult.self, from: Fixtures.data("run_start_queued")).run
        #expect(run.state == .queued && run.state.words == "Waits for a slot" && run.state.station == .run)
        #expect(!run.state.needsYou && !run.state.ended)
        #expect(run.note == "Waits for a slot: 2 of 2 runs are running" && run.turns == 0)
    }

    @Test func runStatesMapToTheStationsOfTheLine() {
        #expect(RunState.shaping.station == .shape)
        #expect([RunState.queued, .starting, .running, .startUnknown].allSatisfy { $0.station == .run })
        #expect(RunState.shipping.station == .ship)
        #expect(RunState.ready.station == .land)
        #expect([RunState.stopped, .limited].allSatisfy { $0.station == .stopped })
        #expect(RunState.landed.station == .landed)
        #expect([RunState.cancelled, .skipped, .unknown].allSatisfy { $0.station == nil })
    }

    @Test func aRunWithNoStationIsInNoTileAndNoLine() {
        let today = TodayContent(runs: [Self.run("x", plot: "p1", .cancelled)], plots: Self.plots, now: Self.now)
        #expect(today.line.isEmpty)
        #expect(today.tiles.allSatisfy { $0.count == 0 })
    }
}
