import Foundation
import Testing
@testable import LoamKit

/// Ticket 203: Today groups the runs for the desk tiles, the line, and the recent list. Ticket 206 adds Ship,
/// where a run waits for its PR and CI, and Land, where a ready run waits for you.
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
        // Needs you first, oldest wait first, then the rest newest first.
        #expect(today.needsYou.map(\.run.id) == ["a", "b", "c"])
    }

    @Test func theLineHasARowForEachPlotWithRuns() {
        let runs = [
            Self.run("a", plot: "p1", .shaping), Self.run("b", plot: "p1", .running), Self.run("c", plot: "p1", .startUnknown),
            Self.run("d", plot: "p2", .ready), Self.run("h", plot: "p2", .shipping),
            Self.run("e", plot: "p2", .landed, updated: "2026-10-25T10:00:00Z"),
            Self.run("f", plot: "p2", .landed, updated: "2026-10-10T10:00:00Z"),  // over a week ago
            Self.run("g", plot: "gone", .running),  // a plot that is not in the list
        ]
        let line = TodayContent(runs: runs, plots: Self.plots, now: Self.now).line
        #expect(line.map(\.plotName) == ["Loam", "Reporting"])
        #expect(line[0].counts == [.shape: 1, .run: 2])
        #expect(line[1].counts == [.ship: 1, .land: 1, .landed: 1])
        #expect(TodayContent.lineStations == [.shape, .run, .ship, .land, .stopped, .landed])
    }

    @Test func recentListsTheNewestFirstWithTheirPlot() {
        let runs = [
            Self.run("old", plot: "p1", .cancelled, updated: "2026-10-26T09:00:00Z"),
            Self.run("new", plot: "p2", .ready, updated: "2026-10-27T17:30:00Z"),
        ]
        let recent = TodayContent(runs: runs, plots: Self.plots, now: Self.now).recent
        #expect(recent.map(\.run.id) == ["new", "old"])
        #expect(recent.map(\.plotName) == ["Reporting", "Loam"])
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
        #expect(today.recent.count == 1)
    }
}
