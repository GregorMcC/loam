import Foundation

/// A place on the line that work moves along. Stopped is where a run waits for you after the gate
/// gave up, or after a limit.
public enum RunStation: String, Equatable, Hashable, Sendable, CaseIterable {
    case shape, run, ship, stopped, landed

    public var words: String {
        switch self {
        case .shape: "Shape"
        case .run: "Run"
        case .ship: "Ship"
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
        case .starting, .running, .startUnknown: .run
        case .ready: .ship
        case .stopped, .limited: .stopped
        case .landed: .landed
        case .cancelled, .skipped, .unknown: nil
        }
    }
}

/// What Today shows (ticket 203): the desk tiles, the line of each plot, and the runs.
public struct TodayContent: Equatable, Sendable {
    /// One tile of the desk: a station that waits for you, and how many runs wait there.
    public struct Tile: Equatable, Sendable {
        public var station: RunStation
        public var count: Int
    }

    /// One row of the line: the runs of a plot at each station.
    public struct LineRow: Equatable, Sendable, Identifiable {
        public var plotID: String
        public var plotName: String
        public var counts: [RunStation: Int]
        public var id: String { plotID }
    }

    /// A run with the name of its plot and the time it last moved.
    public struct Item: Equatable, Sendable, Identifiable {
        public var run: Run
        public var plotName: String
        /// "HH:MM" today, else "2 Oct, HH:MM".
        public var when: String
        public var id: String { run.id }
    }

    /// The stations of the line, in order.
    public static let lineStations: [RunStation] = [.shape, .run, .ship, .stopped, .landed]
    /// How many runs the recent list shows.
    public static let recentLimit = 12

    public var tiles: [Tile]
    public var line: [LineRow]
    /// The runs that wait for you, the oldest wait first.
    public var needsYou: [Item]
    /// The runs that moved last, newest first.
    public var recent: [Item]
    public var needsYouCount: Int { needsYou.count }

    /// Builds Today from the runs of every plot. A landed run counts on the line for 7 days after it
    /// moved. A run of a plot that is not in `plots` shows nowhere.
    public init(runs: [Run], plots: [PlotSummary], now: Date = Date()) {
        let names = Dictionary(plots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let known = runs.filter { names[$0.plotID] != nil }
        let item = { (run: Run) in
            Item(run: run, plotName: names[run.plotID] ?? "", when: ChangeRules.stamp(run.updatedAt, now: now))
        }
        let onLine = known.filter { run in
            guard let station = run.state.station else { return false }
            return station != .landed || (ChangeRules.date(run.updatedAt).map { $0 >= weekAgo } ?? false)
        }

        tiles = [RunStation.shape, .ship, .stopped].map { station in
            Tile(station: station, count: onLine.filter { $0.state.station == station }.count)
        }
        line = plots.compactMap { plot in
            var counts: [RunStation: Int] = [:]
            for run in onLine where run.plotID == plot.id {
                if let station = run.state.station { counts[station, default: 0] += 1 }
            }
            return counts.isEmpty ? nil : LineRow(plotID: plot.id, plotName: plot.name, counts: counts)
        }
        // The core writes times with the local offset, so order by the time, not by the text.
        let moved = { (run: Run) in ChangeRules.date(run.updatedAt) ?? .distantPast }
        needsYou = known.filter(\.state.needsYou).sorted { moved($0) < moved($1) }.map(item)
        recent = known.sorted { moved($0) > moved($1) }.prefix(Self.recentLimit).map(item)
    }
}
