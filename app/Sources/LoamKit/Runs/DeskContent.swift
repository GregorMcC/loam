import Foundation

/// The text of the desk that comes from the runs, their history and the settings: the queue, the context line of a
/// run, its stations, its evidence, the order of its files, and what an approval does. The views only draw it.
public enum DeskContent {
    // MARK: Queue

    /// One run in the queue column: its title, and a caption with its plot and its issue or PR. The caption of a
    /// stopped run says why it stopped.
    public struct QueueRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var caption: String
        /// The run stopped, so the caption shows in `rust`.
        public var stopped: Bool
    }

    /// The runs of the queue at one station, such as "Shape 2".
    public struct QueueGroup: Equatable, Sendable, Identifiable {
        public var station: RunStation
        public var rows: [QueueRow]
        public var id: RunStation { station }
        public var title: String { "\(station.words) \(rows.count)" }
    }

    /// The queue by station, in the order of the queue. A station with no run has no group.
    public static func queue(_ queue: [Run], plots: [PlotSummary]) -> [QueueGroup] {
        let names = Dictionary(plots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var groups: [QueueGroup] = []
        for run in queue {
            guard let station = run.state.station else { continue }
            let plot = names[run.plotID] ?? ""
            let caption: [String] = switch station {
            case .shape: [plot, run.source?.label ?? ""]
            case .land: [plot, run.pr.map { "#\($0.number)" } ?? run.source?.label ?? ""]
            default: [run.pr.map { "#\($0.number)" } ?? plot, shortReason(run.note)]
            }
            let row = QueueRow(id: run.id, title: run.title, caption: joined(caption), stopped: station == .stopped)
            if let i = groups.firstIndex(where: { $0.station == station }) {
                groups[i].rows.append(row)
            } else {
                groups.append(QueueGroup(station: station, rows: [row]))
            }
        }
        return groups
    }

    /// The note of a stopped run up to its first colon, full stop or line end, such as "CI failed after 3 tries".
    public static func shortReason(_ note: String) -> String {
        let ends = [note.firstIndex { ":\n".contains($0) }, note.range(of: ". ")?.lowerBound].compactMap { $0 }
        let end = ends.min() ?? note.endIndex
        var reason = String(note[..<end]).trimmingCharacters(in: .whitespaces)
        if reason.hasSuffix(".") { reason.removeLast() }
        return reason
    }

    // MARK: Context

    /// The line above the title: the station, the plot, the issue and the PR. A draft says when Claude shaped it,
    /// and which recurring run asked for it. A run that is ready says since when. A stopped run counts its tries.
    public static func context(_ run: Run, plotName: String, repoName: String = "", events: [RunEvent],
                               recurringTitle: String? = nil, timeZone: TimeZone = .current) -> String {
        let station = run.state.station ?? .stopped
        var parts = [station == .land || station == .shape ? station.words : RunStation.stopped.words, plotName]
        if let source = run.source, source.kind != "recurring" { parts.append(source.key) }
        if !run.groupID.isEmpty { parts.append(repoName) }
        if let pr = run.pr { parts.append("#\(pr.number)") }
        switch station {
        case .shape:
            if let drafted = run.shape?.draftedAt {
                var shaped = "shaped at \(ChangeRules.clock(drafted, timeZone: timeZone))"
                if let recurringTitle, !recurringTitle.isEmpty { shaped += " by \u{201C}\(recurringTitle)\u{201D}" }
                parts.append(shaped)
            }
        case .land:
            if let ready = events.last(where: { $0.kind == "state" && $0.detail == RunState.ready.rawValue }) {
                parts.append("ready since \(ChangeRules.clock(ready.at, timeZone: timeZone))")
            }
        default:
            parts.append("\(run.tries) of \(run.maxTries) tries used")
        }
        return joined(parts)
    }

    // MARK: Stations

    /// What each station did with a run that is ready or stopped: when you approved its draft, its turns and
    /// tries, and its CI. A station with no record shows nothing.
    public static func stations(_ run: Run, events: [RunEvent], timeZone: TimeZone = .current) -> [String] {
        var out: [String] = []
        if run.shape != nil, let approved = approval(events) {
            out.append("Shape: you approved \(ChangeRules.clock(approved.at, timeZone: timeZone))")
        }
        let tries = attempts(run)
        out.append("Run: \(count(run.turns, "turn")), \(count(tries, "try", "tries"))")
        if let ci = events.last(where: { $0.kind == "ci" }) {
            if let passed = ciPassed(ci.detail) {
                out.append("Ship: CI \(passed.passed) of \(passed.total)")
            } else {
                out.append("Ship: CI failed")
            }
        }
        return out
    }

    /// The state event that left Shaping: the first start after the last time that the run was in Shaping.
    static func approval(_ events: [RunEvent]) -> RunEvent? {
        let states = events.filter { $0.kind == "state" }
        guard let shaping = states.lastIndex(where: { $0.detail == RunState.shaping.rawValue }) else { return nil }
        return states[(shaping + 1)...].first {
            $0.detail == RunState.starting.rawValue || $0.detail == RunState.queued.rawValue
        }
    }

    /// The tries that the run took. `tries` counts the tries that the gate or CI failed, so a run that is ready
    /// took one more.
    static func attempts(_ run: Run) -> Int {
        run.state == .ready ? run.tries + 1 : max(run.tries, 1)
    }

    /// The counts of a CI event such as "CI passed on #1: 14 of 14 checks", or nil for one that did not pass.
    static func ciPassed(_ detail: String) -> (passed: Int, total: Int, pr: Int)? {
        let words = detail.split(whereSeparator: { " :#".contains($0) })
        guard words.count >= 7, words[0] == "CI", words[1] == "passed", words[2] == "on", words[5] == "of",
              let pr = Int(words[3]), let passed = Int(words[4]), let total = Int(words[6]) else { return nil }
        return (passed, total, pr)
    }

    // MARK: Evidence

    /// One line of the evidence: a tick, or a count, a title, and a caption.
    public struct EvidenceLine: Equatable, Sendable, Identifiable {
        public enum Mark: Equatable, Sendable {
            case tick
            case count(Int)
            case none
        }

        public var id: String
        public var mark: Mark
        public var title: String
        public var caption: String
    }

    /// Why the run is at the desk: the last result of the gate, the tries that the gate or CI sent back, and CI.
    public static func evidence(_ run: Run, events: [RunEvent], timeZone: TimeZone = .current) -> [EvidenceLine] {
        var lines: [EvidenceLine] = []
        let checks = lastGate(events)
        if let last = checks.last {
            let passed = checks.filter { $0.detail.contains(" passed (") }
            if passed.count == checks.count {
                lines.append(EvidenceLine(
                    id: "checks", mark: .tick, title: "Done when \u{00B7} \(checks.count) of \(checks.count) checks",
                    caption: "All passed on try \(attempts(run)) at \(ChangeRules.clock(last.at, timeZone: timeZone))"))
            } else {
                let failed = checks.filter { !$0.detail.contains(" passed (") }
                lines.append(EvidenceLine(
                    id: "checks", mark: .count(failed.count),
                    title: "Done when \u{00B7} \(passed.count) of \(checks.count) checks passed",
                    caption: failed.map(\.detail).joined(separator: ", ")))
            }
        }
        if run.tries > 0 {
            let tries = events.filter { $0.kind == "try" }
            lines.append(EvidenceLine(
                id: "tries", mark: .count(run.tries),
                title: run.tries == 1 ? "The gate or CI sent it back once" : "The gate or CI sent it back \(run.tries) times",
                caption: tries.last.map { "Try \(tries.count): \($0.detail)" } ?? ""))
        }
        if let ci = events.last(where: { $0.kind == "ci" }) {
            if let passed = ciPassed(ci.detail) {
                lines.append(EvidenceLine(id: "ci", mark: .tick, title: "CI \u{00B7} \(passed.passed) of \(passed.total) on #\(passed.pr)",
                                          caption: ChangeRules.clock(ci.at, timeZone: timeZone)))
            } else {
                lines.append(EvidenceLine(id: "ci", mark: .none, title: ci.detail, caption: ChangeRules.clock(ci.at, timeZone: timeZone)))
            }
        }
        return lines
    }

    /// The check events of the last run of the gate: the gate records its results one after the other.
    static func lastGate(_ events: [RunEvent]) -> [RunEvent] {
        guard let end = events.lastIndex(where: { $0.kind == "check" }) else { return [] }
        let start = events[..<end].lastIndex { $0.kind != "check" }.map { $0 + 1 } ?? events.startIndex
        return Array(events[start...end])
    }

    // MARK: Files

    /// A file of the diff, with its role in the change from the ship notes.
    public struct ReadFile: Equatable, Sendable, Identifiable {
        public var file: RunDiff.File
        /// The role from the notes, such as "Tests", or nil when the notes do not list the file.
        public var role: String?
        public var id: String { file.path }
    }

    /// The files of the diff in the order that the notes give. The files that the notes do not list follow in the
    /// order of git. A file of the notes that the diff does not have is left out.
    public static func readOrder(_ files: [RunDiff.File], notes: RunNotes?) -> [ReadFile] {
        guard let notes else { return files.map { ReadFile(file: $0) } }
        var out: [ReadFile] = []
        for note in notes.files {
            if let file = files.first(where: { $0.path == note.path }), !out.contains(where: { $0.file.path == file.path }) {
                out.append(ReadFile(file: file, role: note.role.isEmpty ? nil : note.role))
            }
        }
        out += files.filter { file in !out.contains { $0.file.path == file.path } }.map { ReadFile(file: $0) }
        return out
    }

    /// The lines that the files add and delete, such as "+91 −8".
    public static func lineCounts(_ files: [RunDiff.File]) -> String {
        "+\(files.reduce(0) { $0 + $1.added }) \u{2212}\(files.reduce(0) { $0 + $1.deleted })"
    }

    /// The caption of a file: its role, or its status with no notes, its line counts, and your notes on it.
    public static func fileCaption(_ file: ReadFile, notes: Int) -> String {
        var counts: [String] = []
        if file.file.added > 0 { counts.append("+\(file.file.added)") }
        if file.file.deleted > 0 { counts.append("\u{2212}\(file.file.deleted)") }
        return joined([file.role ?? file.file.status.capitalized, counts.joined(separator: " "),
                       notes == 0 ? "" : count(notes, "note")])
    }

    // MARK: If you approve

    /// When the run starts: now while a slot is free and no run waits for one, else when a slot frees.
    public static func starts(limits: RunLimits, runs: [Run]) -> String {
        let running = runs.filter { [.starting, .running, .startUnknown].contains($0.state) }.count
        let waits = runs.contains { $0.state == .queued }
        let now = running < limits.atATime && !waits
        return "\(now ? "Now" : "When a slot frees"). \(running) of \(limits.atATime) runs are running"
    }

    /// The limits of the run: its turns and its tries at the gate.
    public static func limits(_ limits: RunLimits?, maxTries: Int) -> String {
        var parts: [String] = []
        if let limits { parts.append(limits.maxTurns == 0 ? "No turn limit" : count(limits.maxTurns, "turn")) }
        parts.append("\(count(maxTries, "try", "tries")) at the gate")
        return joined(parts)
    }

    // MARK: Words

    static func count(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) \(n == 1 ? one : many ?? one + "s")"
    }

    static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
