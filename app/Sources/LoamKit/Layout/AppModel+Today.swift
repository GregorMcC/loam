import Foundation

/// What Today reads besides the runs: the intake of each plot, the run limits, the usage, the recurring runs, and the
/// run events since you last left Today.
public struct TodayData: Equatable, Sendable {
    /// The intake of a plot as the app last read it, and when.
    public struct IntakeRead: Equatable, Sendable {
        public var list: IntakeList
        public var at: Date
    }

    /// The intake of each plot, from Today or the Intake page.
    public var intake: [String: IntakeRead] = [:]
    /// When the app last read each intake source of each plot without an error, by `TodayWords.sourceKey`.
    public var sourceReads: [String: [String: Date]] = [:]
    public var limits: RunLimits?
    public var usage: Usage?
    /// When the app last asked Claude Code for its usage. A refresh costs a small Claude call.
    public var usageRefreshTried: Date?
    /// The recurring runs of every plot.
    public var recurring: [Recurring] = []
    /// The run events since `awaySince`, the newest first.
    public var awayEvents: [RunFeedEvent] = []
    public var awaySince: Date?
    /// When you last left Today, or nil before the first time.
    public var leftAt: Date?
    /// `leftAt` was read from `state.json`.
    var leftAtLoaded = false
}

extension AppModel {
    /// The `state.json` key of the time when you last left Today.
    public static let todayLeftAtKey = "today_left_at"
    /// How long Today keeps the intake of a plot before it reads it again.
    public static let intakeCacheAge: TimeInterval = 5 * 60
    /// How old the usage can be before Today asks Claude Code again.
    public static let usageMaxAge: TimeInterval = 30 * 60
    /// "While you were away" with no time of leaving shows the events of this many seconds.
    public static let firstAwayWindow: TimeInterval = 24 * 3600

    /// What Today shows, from the runs, the plots, and what Today read.
    public var today: TodayContent {
        let repos = repoCheckouts.compactMapValues { checkouts in
            checkouts.first(where: \.isMain).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        }
        return TodayContent(runs: runs, plots: plots, now: now(), intake: todayData.intake.mapValues(\.list),
                            repoNames: repos, recurring: todayData.recurring)
    }

    /// The open intake items of every plot that the app has read.
    public var intakeCount: Int { todayData.intake.values.reduce(0) { $0 + $1.list.items.count } }

    /// The plot whose Intake page Start a run opens: the active plot, else the first plot with an intake source, else
    /// the first plot.
    public var startRunPlot: String? {
        workspace.activePlotID
            ?? plots.first { todayData.intake[$0.id]?.list.sources.isEmpty == false }?.id
            ?? plots.first?.id
    }

    /// Reads what Today shows besides the runs. A failed read keeps the last value. The intake of a plot is read
    /// again only after `intakeCacheAge`.
    public func readToday() async {
        await readAwayEvents()
        if let limits = try? await client.runLimits() { todayData.limits = limits }
        if let all = try? await client.recurringList() { todayData.recurring = all }
        await readIntakeOfEachPlot()
    }

    /// Reads the usage. When it is older than `usageMaxAge`, or never read, it asks Claude Code with a small Claude
    /// call, at most once in `usageMaxAge`. Only Today calls this, never the change feed.
    public func readUsage() async {
        if let usage = try? await client.usage() { todayData.usage = usage }
        let readAt = todayData.usage?.readAt.flatMap(ChangeRules.date)
        let current = now()
        guard readAt.map({ current.timeIntervalSince($0) > Self.usageMaxAge }) ?? true,
              todayData.usageRefreshTried.map({ current.timeIntervalSince($0) > Self.usageMaxAge }) ?? true
        else { return }
        todayData.usageRefreshTried = current
        if let usage = try? await client.usage(refresh: true) { todayData.usage = usage }
    }

    /// Reads the intake of each plot whose last read is older than `intakeCacheAge`.
    func readIntakeOfEachPlot() async {
        for plot in plots.map(\.id) {
            if let read = todayData.intake[plot], now().timeIntervalSince(read.at) < Self.intakeCacheAge { continue }
            guard let list = try? await client.intake(plot: plot) else { continue }
            noteIntakeRead(list)
        }
    }

    /// Keeps an intake list that the app read, and when it read each source.
    func noteIntakeRead(_ list: IntakeList) {
        let at = now()
        todayData.intake[list.plotID] = TodayData.IntakeRead(list: list, at: at)
        for source in list.sources where source.error.isEmpty {
            todayData.sourceReads[list.plotID, default: [:]][TodayWords.sourceKey(source)] = at
        }
    }

    /// Reads the run events since you last left Today, or of the last day the first time.
    func readAwayEvents() async {
        loadTodayLeftAt()
        let since = todayData.leftAt ?? now().addingTimeInterval(-Self.firstAwayWindow)
        guard let feed = try? await client.runEvents(since: Self.rfc3339(since)) else { return }
        todayData.awaySince = since
        todayData.awayEvents = feed.events
    }

    /// You left Today: the next visit shows the events from now on.
    func leftToday() {
        let at = now()
        todayData.leftAt = at
        todayData.leftAtLoaded = true
        stateWriter?.setChanged(Self.todayLeftAtKey) { Self.rfc3339(at) }
    }

    private func loadTodayLeftAt() {
        guard !todayData.leftAtLoaded else { return }
        todayData.leftAtLoaded = true
        if let text = stateWriter?.file.value(forKey: Self.todayLeftAtKey) as? String {
            todayData.leftAt = ChangeRules.date(text)
        }
    }

    static func rfc3339(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }
}
