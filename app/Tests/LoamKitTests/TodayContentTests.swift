import Foundation
import Testing
@testable import LoamKit

/// Ticket 203: Today groups the runs for the desk tiles, the line, and the recent list.
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
            Self.run("d", plot: "p2", .ready), Self.run("e", plot: "p1", .running),
        ]
        let today = TodayContent(runs: runs, plots: Self.plots, now: Self.now)
        #expect(today.tiles.map(\.station) == [.shape, .ship, .stopped])
        #expect(today.tiles.map(\.count) == [1, 1, 2])
        #expect(today.needsYouCount == 3)
        // Needs you first, oldest wait first, then the rest newest first.
        #expect(today.needsYou.map(\.run.id) == ["a", "b", "c"])
    }

    @Test func theLineHasARowForEachPlotWithRuns() {
        let runs = [
            Self.run("a", plot: "p1", .shaping), Self.run("b", plot: "p1", .running), Self.run("c", plot: "p1", .startUnknown),
            Self.run("d", plot: "p2", .ready),
            Self.run("e", plot: "p2", .landed, updated: "2026-10-25T10:00:00Z"),
            Self.run("f", plot: "p2", .landed, updated: "2026-10-10T10:00:00Z"),  // over a week ago
            Self.run("g", plot: "gone", .running),  // a plot that is not in the list
        ]
        let line = TodayContent(runs: runs, plots: Self.plots, now: Self.now).line
        #expect(line.map(\.plotName) == ["Loam", "Reporting"])
        #expect(line[0].counts == [.shape: 1, .run: 2])
        #expect(line[1].counts == [.ship: 1, .landed: 1])
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

    @Test func runStatesMapToTheStationsOfTheLine() {
        #expect(RunState.shaping.station == .shape)
        #expect([RunState.starting, .running, .startUnknown].allSatisfy { $0.station == .run })
        #expect(RunState.ready.station == .ship)
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
