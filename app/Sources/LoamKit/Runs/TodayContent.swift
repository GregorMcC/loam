import Foundation

/// A place on the line that work moves along. Ship is where a run waits for its PR and CI, and Land
/// is where a ready run waits for you. Stopped is where a run waits for you after the gate or CI
/// gave up, or after a limit.
public enum RunStation: String, Equatable, Hashable, Sendable, CaseIterable {
    case shape, run, ship, land, stopped, landed

    public var words: String {
        switch self {
        case .shape: "Shape"
        case .run: "Run"
        case .ship: "Ship"
        case .land: "Land"
        case .stopped: "Stopped"
        case .landed: "Landed this week"
        }
    }
}

extension RunState {
    /// The station of the state. Nil for a run that left the line: cancelled, skipped, or unknown.
    public var station: RunStation? {
        switch self {
        case .shaping: .shape
        case .queued, .starting, .running, .startUnknown: .run
        case .shipping: .ship
        case .ready: .land
        case .stopped, .limited: .stopped
        case .landed: .landed
        case .cancelled, .skipped, .unknown: nil
        }
    }

    /// The run holds a slot of the run limits: its session starts or works.
    public var holdsSlot: Bool { self == .starting || self == .running || self == .startUnknown }
}

extension Run {
    /// The short ID of the run for a person: the number of its PR, else the key of its issue or ticket, with no
    /// repo before the number of a GitHub issue. Empty for a run with neither, and for a run that a recurring run
    /// started, whose key is an ID.
    public var shortKey: String {
        if let pr { return "#\(pr.number)" }
        guard let source, source.kind != "recurring" else { return "" }
        if source.kind == "github", let number = source.key.lastIndex(of: "#") { return String(source.key[number...]) }
        return source.key
    }

    /// The column of the line where the run sits. A stopped run sits where it stopped: Ship when it has a PR, else
    /// Run. Nil for a run that left the line.
    public var lineStation: RunStation? {
        guard state.station == .stopped else { return state.station }
        return pr == nil ? .run : .ship
    }
}

/// What Today shows (ticket 203): the desk tiles, and the line of each plot with a chip for each run.
public struct TodayContent: Equatable, Sendable {
    /// One tile of the desk: a station that waits for you, the first runs that wait there, and a line about them.
    public struct Tile: Equatable, Sendable {
        public var station: RunStation
        public var count: Int
        /// The runs that the tile names, the longest wait first.
        public var runs: [TileRun]
        /// How long the runs wait, such as "oldest 2 h". Nil when none waits.
        public var age: String?
        /// One line from the runs, such as the note of a stopped run. Nil when the runs say nothing more.
        public var context: String?
        /// The context is why a run stopped.
        public var contextStops: Bool
    }

    /// A run that a tile names: "title · #PR", "title · KEY", or the title.
    public struct TileRun: Equatable, Sendable, Identifiable {
        public var runID: String
        public var words: String
        public var id: String { runID }
    }

    /// One run in a cell of the line.
    public struct Chip: Equatable, Sendable, Identifiable {
        public enum Mark: Equatable, Sendable { case needsYou, doneUnread, none }
        public var runID: String
        public var mark: Mark
        /// The PR or the issue key, in mono. Empty when the run has neither, and then the chip shows the title.
        public var key: String
        public var title: String
        /// A short state, such as "Turn 12" or "CI, try 2 of 3". For a run in Shape it is the title.
        public var state: String
        /// The run stopped: the state shows in rust.
        public var stopped: Bool
        /// The run waits for a slot: the chip has a dashed edge.
        public var waits: Bool
        public var id: String { runID }
    }

    /// The Intake cell of a plot: how many items it has, and how many are new.
    public struct IntakeCell: Equatable, Sendable {
        public var count: String
        public var caption: String?
        /// The plot has no intake source: the cell says "None".
        public var none = false
    }

    /// One row of the line: a plot, its intake, and its runs at each station.
    public struct LineRow: Equatable, Sendable, Identifiable {
        public var plotID: String
        public var plotName: String
        /// The Linear team key and the repo, such as "ENG · loam", or "No Linear link".
        public var caption: String
        /// Nil while the intake of the plot is not read.
        public var intake: IntakeCell?
        public var chips: [RunStation: [Chip]]
        /// The runs that landed in the last 7 days.
        public var landed: Int
        public var id: String { plotID }
    }

    /// The columns of the line with chips, in order. Landed this week is a count after them.
    public static let lineStations: [RunStation] = [.shape, .run, .ship, .land]
    /// How many runs a tile names.
    public static let tileRunLimit = 2

    public var tiles: [Tile]
    public var line: [LineRow]
    /// The runs on the line that need you: Shape, Stopped, and Stopped by a limit, the longest wait first.
    public var needsYou: [Run]
    public var needsYouCount: Int { needsYou.count }
    /// The runs on the line that are done, unread: Ready to land, the longest wait first (TAS-45).
    public var doneUnread: [Run]
    /// The runs that wait for you in any way. The Today row of the sidebar counts them.
    public var waitsForYouCount: Int { needsYou.count + doneUnread.count }

    /// Builds Today from the runs of every plot. A landed run counts on the line for 7 days after it moved. A run of
    /// a plot that is not in `plots` shows nowhere. `intake` holds the intake of each plot that is read, `repoNames`
    /// the folder name of the main repo of each plot, and `recurring` the recurring runs of every plot. A plot is on
    /// the line when it has a run there or an intake source.
    public init(runs: [Run], plots: [PlotSummary], now: Date = Date(), intake: [String: IntakeList] = [:],
                repoNames: [String: String] = [:], recurring: [Recurring] = [], timeZone: TimeZone = .current) {
        let known = Set(plots.map(\.id))
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        // The core writes times with the local offset, so order by the time, not by the text.
        let moved = { (run: Run) in ChangeRules.date(run.updatedAt) ?? .distantPast }
        let onLine = runs.filter { known.contains($0.plotID) && $0.state.station != nil }
            .filter { $0.state.station != .landed || moved($0) >= weekAgo }
            .sorted { moved($0) < moved($1) }

        tiles = [RunStation.shape, .land, .stopped].map { station in
            Self.tile(station, runs: onLine.filter { $0.state.station == station }, now: now, recurring: recurring,
                      timeZone: timeZone)
        }
        line = plots.compactMap { plot in
            let mine = onLine.filter { $0.plotID == plot.id }
            let list = intake[plot.id]
            guard !mine.isEmpty || list?.sources.isEmpty == false else { return nil }
            var chips: [RunStation: [Chip]] = [:]
            for run in mine {
                if let station = run.lineStation, station != .landed { chips[station, default: []].append(Self.chip(run)) }
            }
            return LineRow(plotID: plot.id, plotName: plot.name,
                           caption: Self.plotCaption(intake: list, repo: repoNames[plot.id] ?? ""),
                           intake: list.map { Self.intakeCell($0, now: now) }, chips: chips,
                           landed: mine.filter { $0.state == .landed }.count)
        }
        needsYou = onLine.filter(\.state.needsYou)
        doneUnread = onLine.filter(\.state.doneUnread)
    }

    // MARK: Tiles

    static func tile(_ station: RunStation, runs: [Run], now: Date, recurring: [Recurring], timeZone: TimeZone) -> Tile {
        let named = runs.prefix(tileRunLimit).map { TileRun(runID: $0.id, words: tileWords($0)) }
        var tile = Tile(station: station, count: runs.count, runs: named, age: nil, context: nil, contextStops: false)
        guard let oldest = runs.first, let since = ChangeRules.date(oldest.updatedAt) else { return tile }
        switch station {
        case .shape:
            tile.age = "oldest " + duration(now.timeIntervalSince(since))
            tile.context = runs.lazy.compactMap { run in
                guard run.source?.kind == "recurring", let source = recurring.first(where: { $0.id == run.source?.key })
                else { return nil }
                return "Shaped by the \(source.at) recurring run"
            }.first
        case .land:
            tile.age = "ready since " + ChangeRules.stamp(since, now: now, timeZone: timeZone)
            tile.context = runs.allSatisfy { $0.pr != nil } ? "All checks and CI passed" : "All checks passed"
        case .stopped:
            tile.age = "since " + ChangeRules.stamp(since, now: now, timeZone: timeZone)
            let note = oldest.note.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            tile.context = note.isEmpty ? nil : note
            tile.contextStops = !note.isEmpty
        case .run, .ship, .landed:
            break
        }
        return tile
    }

    /// "title · #PR", "title · KEY", or the title.
    static func tileWords(_ run: Run) -> String {
        run.shortKey.isEmpty ? run.title : "\(run.title) \u{00B7} \(run.shortKey)"
    }

    /// A wait for a person: "5 min", "2 h", or "3 d". A wait under a minute is "1 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours < 48 ? "\(hours) h" : "\(hours / 24) d"
    }

    // MARK: The line

    static func chip(_ run: Run) -> Chip {
        let mark: Chip.Mark = run.state.needsYou ? .needsYou : run.state.doneUnread ? .doneUnread : .none
        return Chip(runID: run.id, mark: mark, key: run.shortKey, title: run.title, state: chipState(run),
                    stopped: run.state == .stopped || run.state == .limited, waits: run.state == .queued)
    }

    /// The short state of a run on the line.
    static func chipState(_ run: Run) -> String {
        let attempt = "\(min(run.tries + 1, run.maxTries)) of \(run.maxTries)"
        switch run.state {
        case .shaping: return run.title
        case .running:
            if run.tries > 0 { return "Try \(attempt)" }
            return run.turns > 0 ? "Turn \(run.turns)" : run.state.words
        case .shipping:
            guard run.pr != nil else { return run.state.words }
            return run.tries > 0 ? "CI, try \(attempt)" : "Waits for CI"
        case .ready: return "Ready"
        case .limited: return "Usage limit"
        default: return run.state.words
        }
    }

    /// The Linear team keys of the issues and the repo of the plot, such as "ENG · loam". "No Linear link" when no
    /// source of the plot is Linear.
    static func plotCaption(intake: IntakeList?, repo: String) -> String {
        guard let intake, intake.sources.contains(where: { $0.kind == "linear" }) else { return "No Linear link" }
        var teams: [String] = []
        for item in intake.items where item.source == "linear" {
            if let team = item.key.split(separator: "-").first.map(String.init), !teams.contains(team) { teams.append(team) }
        }
        return (teams + [repo]).filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// "11 issues" and "3 new since yesterday", from the intake of the plot. Items made in the last 24 hours are new.
    /// A list with a map ticket counts items, and a list of map tickets only says they are "from the plot's map".
    static func intakeCell(_ list: IntakeList, now: Date) -> IntakeCell {
        guard !list.sources.isEmpty else { return IntakeCell(count: "None", caption: nil, none: true) }
        let n = list.items.count
        let anyTicket = list.items.contains(where: \.isTicket)
        let noun = anyTicket ? (n == 1 ? "item" : "items") : (n == 1 ? "issue" : "issues")
        let dayAgo = now.addingTimeInterval(-24 * 3600)
        let new = list.items.filter { ChangeRules.date($0.createdAt).map { $0 >= dayAgo } ?? false }.count
        let caption: String? = if new > 0 {
            "\(new) new since yesterday"
        } else if anyTicket && list.items.allSatisfy(\.isTicket) {
            "from the plot's map"
        } else if n == 0 && list.sources.allSatisfy({ !$0.error.isEmpty }) {
            "Could not read"
        } else {
            nil
        }
        return IntakeCell(count: "\(n) \(noun)", caption: caption)
    }
}
