import Foundation
import Testing

@testable import LoamKit

/// The desk redesign: the queue by station, the context line, the stations, the evidence, the order of the
/// files, and what an approval does, all from the runs and their history.
@Suite struct DeskContentTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let plots = [PlotSummary(id: "p1", name: "Loam redesign", what: "", createdAt: "2026-10-01T09:00:00Z")]

    static func run(_ id: String, _ state: RunState, title: String? = nil) -> Run {
        TodayContentTests.run(id, plot: "p1", state, title: title)
    }

    static func event(_ id: Int, _ kind: String, _ detail: String, at: String = "2026-10-27T08:00:00Z") -> RunEvent {
        RunEvent(id: id, runID: "r1", at: at, kind: kind, detail: detail)
    }

    static func file(_ path: String, added: Int, deleted: Int, status: String = "modified") -> RunDiff.File {
        RunDiff.File(path: path, status: status, added: added, deleted: deleted, hunks: [])
    }

    // MARK: Queue

    @Test func theQueueGroupsTheRunsByStation() {
        var shape = Self.run("s1", .shaping, title: "Remember the window size per plot")
        shape.source = RunSource(kind: "linear", key: "ENG-512", url: "")
        var land = Self.run("l1", .ready, title: "Plot search matches link labels")
        land.pr = RunPR(number: 147, url: "")
        var stopped = Self.run("x1", .stopped, title: "Copy the last command output")
        stopped.pr = RunPR(number: 144, url: "")
        stopped.note = "CI failed after 3 tries: test, lint"
        var noPR = Self.run("x2", .limited, title: "Bump the modules")
        noPR.note = "The run took 40 turns, its limit."

        let groups = DeskContent.queue([shape, land, stopped, noPR], plots: Self.plots)
        #expect(groups.map(\.title) == ["Shape 1", "Land 1", "Stopped 2"])
        #expect(groups[0].rows[0].caption == "Loam redesign \u{00B7} ENG-512")
        #expect(groups[1].rows[0].caption == "Loam redesign \u{00B7} #147")
        #expect(groups[2].rows.map(\.caption)
            == ["#144 \u{00B7} CI failed after 3 tries", "Loam redesign \u{00B7} The run took 40 turns, its limit"])
        #expect(groups[2].rows.allSatisfy(\.stopped) && !groups[0].rows[0].stopped)
    }

    @Test func theShortReasonEndsAtTheFirstClause() {
        #expect(DeskContent.shortReason("Checks failed after 1 try: Guide") == "Checks failed after 1 try")
        #expect(DeskContent.shortReason("The session ended. Loam could not resume it.") == "The session ended")
        #expect(DeskContent.shortReason("") == "")
    }

    // MARK: Context

    @Test func aDraftSaysWhenAndByWhatItWasShaped() {
        var run = Self.run("s1", .shaping)
        run.source = RunSource(kind: "recurring", key: "recuaaaaab", url: "")
        run.shape = RunShape(assumptions: [], plan: [], size: "", draftedAt: "2026-10-27T06:34:00Z", repo: "", base: "",
                             link: "", model: "")
        #expect(DeskContent.context(run, plotName: "Loam redesign", events: [], recurringTitle: "Shape new issues",
                                    timeZone: Self.utc)
            == "Shape \u{00B7} Loam redesign \u{00B7} shaped at 06:34 by \u{201C}Shape new issues\u{201D}")
        run.source = RunSource(kind: "linear", key: "ENG-512", url: "")
        #expect(DeskContent.context(run, plotName: "Loam redesign", events: [], timeZone: Self.utc)
            == "Shape \u{00B7} Loam redesign \u{00B7} ENG-512 \u{00B7} shaped at 06:34")
        run.shape?.draftedAt = nil
        #expect(DeskContent.context(run, plotName: "Loam redesign", events: [], timeZone: Self.utc)
            == "Shape \u{00B7} Loam redesign \u{00B7} ENG-512")
    }

    @Test func aReadyRunSaysSinceWhen() {
        var run = Self.run("r1", .ready)
        run.source = RunSource(kind: "linear", key: "ENG-517", url: "")
        run.pr = RunPR(number: 147, url: "")
        let events = [Self.event(1, "state", "ready", at: "2026-10-27T03:00:00Z"), Self.event(2, "state", "shipping"),
                      Self.event(3, "state", "ready", at: "2026-10-27T04:52:00Z")]
        #expect(DeskContent.context(run, plotName: "Loam redesign", events: events, timeZone: Self.utc)
            == "Land \u{00B7} Loam redesign \u{00B7} ENG-517 \u{00B7} #147 \u{00B7} ready since 04:52")
        let stopped = Self.run("x1", .stopped)
        #expect(DeskContent.context(stopped, plotName: "Loam redesign", events: [], timeZone: Self.utc)
            == "Stopped \u{00B7} Loam redesign \u{00B7} 0 of 3 tries used")
    }

    // MARK: Stations

    @Test func theStationsSayWhatEachOneDid() {
        var run = Self.run("r1", .ready)
        run.turns = 34
        run.tries = 1
        run.shape = RunShape(assumptions: [], plan: [], size: "", draftedAt: "2026-10-27T06:34:00Z", repo: "", base: "",
                             link: "", model: "")
        let events = [Self.event(1, "state", "shaping"), Self.event(2, "state", "queued", at: "2026-10-27T22:05:00Z"),
                      Self.event(3, "state", "starting", at: "2026-10-27T22:30:00Z"), Self.event(4, "ci", "CI passed on #147: 14 of 14 checks")]
        #expect(DeskContent.stations(run, events: events, timeZone: Self.utc)
            == ["Shape: you approved 22:05", "Run: 34 turns, 2 tries", "Ship: CI 14 of 14"])

        // A run that did not start in Shaping has no Shape station. CI that failed says so.
        var plain = Self.run("r2", .stopped)
        plain.turns = 1
        plain.tries = 1
        #expect(DeskContent.stations(plain, events: [Self.event(1, "ci", "CI failed on #3: test")], timeZone: Self.utc)
            == ["Run: 1 turn, 1 try", "Ship: CI failed"])
    }

    // MARK: Evidence

    @Test func theEvidenceIsTheLastGateTheTriesAndCI() {
        var run = Self.run("r1", .ready)
        run.tries = 1
        run.pr = RunPR(number: 147, url: "")
        let events = [
            Self.event(1, "check", "Tests failed (exit 1, 2s)"), Self.event(2, "check", "Committed passed (0s)"),
            Self.event(3, "try", "Checks failed: Tests"), Self.event(4, "state", "running"),
            Self.event(5, "check", "Tests passed (2s)"), Self.event(6, "check", "Committed passed (0s)", at: "2026-10-27T04:31:00Z"),
            Self.event(7, "ci", "CI passed on #147: 14 of 14 checks", at: "2026-10-27T04:52:00Z"),
        ]
        let lines = DeskContent.evidence(run, events: events, timeZone: Self.utc)
        #expect(lines.map(\.mark) == [.tick, .count(1), .tick])
        #expect(lines.map(\.title) == ["Done when \u{00B7} 2 of 2 checks", "The gate or CI sent it back once", "CI \u{00B7} 14 of 14 on #147"])
        #expect(lines.map(\.caption) == ["All passed on try 2 at 04:31", "Try 1: Checks failed: Tests", "04:52"])
    }

    @Test func aGateThatFailedCountsTheFailedChecks() {
        var run = Self.run("r1", .stopped)
        run.tries = 3
        let events = [Self.event(1, "check", "Guide failed (exit 1, 0s)"), Self.event(2, "check", "Committed passed (0s)")]
        let lines = DeskContent.evidence(run, events: events, timeZone: Self.utc)
        #expect(lines.first == DeskContent.EvidenceLine(id: "checks", mark: .count(1), title: "Done when \u{00B7} 1 of 2 checks passed",
                                                        caption: "Guide failed (exit 1, 0s)"))
        #expect(lines.last?.title == "The gate or CI sent it back 3 times")
        #expect(DeskContent.evidence(Self.run("r2", .ready), events: [], timeZone: Self.utc).isEmpty)
    }

    // MARK: Files

    @Test func theNotesGiveTheOrderOfTheFiles() {
        let files = [Self.file("README.md", added: 1, deleted: 0), Self.file("search/match.go", added: 14, deleted: 3),
                     Self.file("search/match_test.go", added: 62, deleted: 0, status: "added")]
        let notes = RunNotes(walkthrough: "Search matches labels.",
                             files: [.init(path: "search/match.go", role: "The rule"), .init(path: "gone.go", role: "Gone"),
                                     .init(path: "search/match_test.go", role: "Tests")],
                             risk: .init(level: "low", reasons: []), whereItStands: "", writtenAt: "")
        let order = DeskContent.readOrder(files, notes: notes)
        #expect(order.map(\.file.path) == ["search/match.go", "search/match_test.go", "README.md"])
        #expect(order.map(\.role) == ["The rule", "Tests", nil])
        #expect(DeskContent.fileCaption(order[0], notes: 2) == "The rule \u{00B7} +14 \u{2212}3 \u{00B7} 2 notes")
        #expect(DeskContent.fileCaption(order[1], notes: 0) == "Tests \u{00B7} +62")
        #expect(DeskContent.fileCaption(order[2], notes: 1) == "Modified \u{00B7} +1 \u{00B7} 1 note")
        #expect(DeskContent.readOrder(files, notes: nil).map(\.file.path) == files.map(\.path))
        #expect(DeskContent.lineCounts(files) == "+77 \u{2212}3")
    }

    // MARK: If you approve

    @Test func aRunStartsNowWhileASlotIsFree() {
        let limits = RunLimits(atATime: 3, maxTurns: 40, holdAt: 80)
        let one = [Self.run("a", .running), Self.run("b", .shipping), Self.run("c", .ready)]
        #expect(DeskContent.starts(limits: limits, runs: one) == "Now. 1 of 3 runs are running")
        let full = [Self.run("a", .running), Self.run("b", .starting), Self.run("c", .startUnknown)]
        #expect(DeskContent.starts(limits: limits, runs: full) == "When a slot frees. 3 of 3 runs are running")
        // A run that waits for a slot goes first.
        #expect(DeskContent.starts(limits: limits, runs: [Self.run("a", .queued)]) == "When a slot frees. 0 of 3 runs are running")
    }

    @Test func theLimitsAreTheTurnsAndTheTries() {
        #expect(DeskContent.limits(RunLimits(atATime: 3, maxTurns: 40, holdAt: 80), maxTries: 3)
            == "40 turns \u{00B7} 3 tries at the gate")
        #expect(DeskContent.limits(RunLimits(atATime: 3, maxTurns: 0, holdAt: 0), maxTries: 1)
            == "No turn limit \u{00B7} 1 try at the gate")
        #expect(DeskContent.limits(nil, maxTries: 2) == "2 tries at the gate")
    }
}
