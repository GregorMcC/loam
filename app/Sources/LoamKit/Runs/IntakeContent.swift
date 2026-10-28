import Foundation

/// What the Intake page shows (ticket 204): the sources that it reads, the rows after the source switch and the filter
/// chips, the words of each row, and the text of the bar that acts on the checked rows.
public enum IntakeContent {
    /// Which source the list shows.
    public enum Source: String, CaseIterable, Sendable {
        case all, linear, github, map

        public var words: String {
            switch self {
            case .all: "All"
            case .linear: "Linear"
            case .github: "GitHub"
            case .map: "The map"
            }
        }
    }

    /// The source switch and the filter chips.
    public struct Filter: Equatable, Sendable {
        public var source = Source.all
        /// Only the Linear issues in the active cycle of their team.
        public var thisCycle = false
        public var assignedToMe = false
        public var hideWithRun = false
        /// Hide the items that someone else has or that are in progress (TAS-50). On by default.
        public var hideTaken = true
        /// The milestone to keep (TAS-51): nil keeps every item, "" keeps the items with no milestone.
        public var milestone: String?

        public init() {}
    }

    /// An item is taken when someone else is its assignee, or when it is in progress. An item with a run is yours,
    /// so it is never taken: the run moves its Linear issue to In Progress.
    public static func isTaken(_ item: IntakeItem) -> Bool {
        item.runID.isEmpty && ((!item.assignee.isEmpty && !item.assignedToMe) || item.inProgress)
    }

    /// One choice of the Milestone menu. A nil milestone is All, and "" is No milestone.
    public struct MilestoneChoice: Equatable, Sendable {
        public var milestone: String?
        public var words: String
    }

    /// The choices of the Milestone menu (TAS-51): All, each milestone in the order of its project, then No milestone.
    /// Milestones with the same place sort by name. Empty when no item of the list has a milestone, so the page shows
    /// no menu.
    public static func milestoneChoices(_ list: IntakeList) -> [MilestoneChoice] {
        var order: [String: Double] = [:]
        for item in list.items where !item.milestone.isEmpty { order[item.milestone] = item.milestoneOrder }
        guard !order.isEmpty else { return [] }
        let names = order.keys.sorted { a, b in order[a] != order[b] ? order[a]! < order[b]! : a < b }
        return [MilestoneChoice(milestone: nil, words: "All milestones")]
            + names.map { MilestoneChoice(milestone: $0, words: $0) }
            + [MilestoneChoice(milestone: "", words: "No milestone")]
    }

    /// The label of the Milestone menu: "Milestone" for All, else the name of the choice.
    public static func milestoneWords(_ milestone: String?) -> String {
        switch milestone {
        case nil: "Milestone"
        case "": "No milestone"
        case let name?: name
        }
    }

    /// One choice of the source switch, with its count.
    public struct SourceChoice: Equatable, Sendable {
        public var source: Source
        public var count: Int
        public var words: String { "\(source.words) \(count)" }
    }

    /// The name of a source kind for a person, such as on the badge of a row.
    public static func sourceWords(_ kind: String) -> String {
        switch kind {
        case "linear": "Linear"
        case "github": "GitHub"
        default: "Map"
        }
    }

    /// The line under the title that names what the page reads, such as "From the plot's links: Linear ENG team,
    /// Loam project · GitHub example/widgets · the plot's map". Empty for a plot with no source.
    public static func readsLine(_ sources: [IntakeSource]) -> String {
        func labels(_ kind: String) -> [String] { sources.filter { $0.kind == kind }.map(\.label) }
        var parts: [String] = []
        if !labels("linear").isEmpty { parts.append("Linear " + labels("linear").joined(separator: ", ")) }
        if !labels("github").isEmpty { parts.append("GitHub " + labels("github").joined(separator: ", ")) }
        switch labels("map").count {
        case 0: break
        case 1: parts.append("the plot's map")
        default: parts.append("the plot's maps")
        }
        return parts.isEmpty ? "" : "From the plot's links: " + parts.joined(separator: " \u{00B7} ")
    }

    /// The choices of the source switch: All, then each source that the plot has a link or an item for.
    public static func sourceChoices(_ list: IntakeList) -> [SourceChoice] {
        Source.allCases.compactMap { source in
            if source == .all { return SourceChoice(source: .all, count: list.items.count) }
            let count = list.items.filter { $0.source == source.rawValue }.count
            guard count > 0 || list.sources.contains(where: { $0.kind == source.rawValue }) else { return nil }
            return SourceChoice(source: source, count: count)
        }
    }

    /// This cycle is a chip only while the list has a Linear issue.
    public static func showsThisCycle(_ list: IntakeList) -> Bool {
        list.items.contains { $0.source == "linear" }
    }

    /// What the sort note says, and its help with the whole rule.
    public static let sortWords = "Sorted by Linear priority, then age"
    public static let sortHelp = "Items with no run first, then by Linear priority, then the oldest first"

    /// The rows that the filter keeps, in the order of the page: the items with no run first, then by Linear
    /// priority, then the oldest first. Items that tie keep the order of the core.
    public static func rows(_ list: IntakeList, filter: Filter) -> [IntakeItem] {
        let kept = list.items.enumerated().filter { _, item in
            (filter.source == .all || item.source == filter.source.rawValue)
                && (!filter.thisCycle || item.inCycle)
                && (!filter.assignedToMe || item.assignedToMe)
                && !(filter.hideWithRun && !item.runID.isEmpty)
                && !(filter.hideTaken && isTaken(item))
                && (filter.milestone == nil || item.milestone == filter.milestone)
        }
        return kept.sorted { a, b in
            let (i, x) = a
            let (j, y) = b
            if x.runID.isEmpty != y.runID.isEmpty { return x.runID.isEmpty }
            if priorityRank(x.priority) != priorityRank(y.priority) { return priorityRank(x.priority) < priorityRank(y.priority) }
            let dx = ChangeRules.date(x.createdAt), dy = ChangeRules.date(y.createdAt)
            if let dx, let dy, dx != dy { return dx < dy }
            return i < j
        }.map(\.element)
    }

    /// A plot in the plot menu of the Intake page (TAS-44).
    public struct PlotChoice: Equatable, Sendable {
        public var plotID: String
        /// The name of the plot, and the count of its intake once the app has read it, such as "Loam · 14 items".
        public var words: String
    }

    /// The plot menu of the Intake page: each plot in sidebar order. The count is the one of the Intake column of Today.
    public static func plotChoices(_ plots: [PlotSummary], intake: [String: IntakeList], now: Date) -> [PlotChoice] {
        plots.map { plot in
            let count = intake[plot.id].map { TodayContent.intakeCell($0, now: now).count }
            return PlotChoice(plotID: plot.id, words: count.map { "\(plot.name) \u{00B7} \($0)" } ?? plot.name)
        }
    }

    /// The row that a key selects (TAS-47): the row `step` places after the focused row. The focused row is the
    /// selected row, or the first row when the filter hides the selected row. The move stops at the first and the last
    /// row. Nil for an empty list.
    public static func move(from selected: String?, in rows: [IntakeItem], by step: Int) -> String? {
        guard !rows.isEmpty else { return nil }
        let current = rows.firstIndex { $0.id == selected } ?? 0
        return rows[min(max(current + step, 0), rows.count - 1)].id
    }

    /// The place of a Linear priority in the sort: Urgent first, and an item with none last.
    static func priorityRank(_ priority: String) -> Int {
        ["Urgent", "High", "Medium", "Low"].firstIndex(of: priority) ?? 4
    }

    /// The Status column: the status and the labels, such as "Open · bug".
    public static func statusWords(_ item: IntakeItem) -> String {
        ([item.status] + item.labels).filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// The Priority column: the Linear priority, or "None".
    public static func priorityWords(_ item: IntakeItem) -> String {
        item.priority.isEmpty ? "None" : item.priority
    }

    /// The line under the title of the detail: the assignee and the milestone, such as "Assigned to Bob Example ·
    /// Milestone Alpha". Empty for neither.
    public static func detailFacts(_ item: IntakeItem) -> String {
        [item.assignee.isEmpty ? "" : "Assigned to \(item.assignee)", item.milestone.isEmpty ? "" : "Milestone \(item.milestone)"]
            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// The line at the top right of the detail: the status and the priority, such as "Todo · High".
    public static func statusLine(_ item: IntakeItem) -> String {
        [item.status, item.priority].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    // MARK: Run column

    /// The mark before the words of the Run column: a dot for a run that waits for you, a ring for a run that is
    /// ready to land.
    public enum RunMark: Equatable, Sendable {
        case none, needsYou, ready
    }

    /// The Run column: the station of the run, such as "Run, try 2 of 3" or "Land #147", or "None" for no run.
    public static func runWords(_ run: Run?) -> (words: String, mark: RunMark) {
        guard let run else { return ("None", .none) }
        let pr = run.pr.map { " #\($0.number)" } ?? ""
        switch run.state {
        case .shaping:
            return run.shape?.isDrafted == false ? ("Shape, Claude drafts", .none) : ("Shape, waits for you", .needsYou)
        case .queued: return ("Waits for a slot", .none)
        case .starting, .running: return ("Run, try \(min(run.tries + 1, max(run.maxTries, 1))) of \(run.maxTries)", .none)
        case .startUnknown: return ("Run, start unknown", .none)
        case .shipping: return ("Ship" + pr, .none)
        case .ready: return ("Land" + pr, .ready)
        case .stopped: return ("Stopped, waits for you", .needsYou)
        case .limited: return ("Stopped by a limit", .needsYou)
        case .landed: return ("Landed" + pr, .none)
        case .cancelled, .skipped, .unknown: return (run.state.words, .none)
        }
    }

    // MARK: Detail

    /// The line under the text of the item, which says what the run gets.
    public static func fromWords(_ item: IntakeItem) -> String {
        switch item.source {
        case "linear": "From Linear. The run gets the link to this issue, not a copy of the text."
        case "github": "From GitHub. The run gets the link to this issue, not a copy of the text."
        default: "From the map. The run gets the path of this ticket, not a copy of the text."
        }
    }

    /// The button that opens the item where it lives.
    public static func openWords(_ item: IntakeItem) -> String {
        switch item.source {
        case "linear": "Open in Linear"
        case "github": "Open on GitHub"
        default: "Open the ticket"
        }
    }

    // MARK: The bar of the checked rows

    /// How the bar acts on the checked rows.
    public enum BatchKind: String, CaseIterable, Sendable {
        /// Claude shapes each one, and you approve each draft at the desk.
        case feature
        /// Each one starts as a run at once, with no goal from Claude.
        case chore

        public var words: String {
            switch self {
            case .feature: "Feature: Shape first"
            case .chore: "Chore: start now"
            }
        }
    }

    /// The choices of the Shape picker: Now, and the split when the plot has 2 repos or more.
    public static func shapeChoices(repoCount: Int) -> [(split: Bool, words: String)] {
        repoCount < 2 ? [(false, "Now")] : [(false, "Now"), (true, "Split across the repos")]
    }

    /// The primary button of the bar, such as "Shape 3 runs".
    public static func batchButton(count: Int, kind: BatchKind) -> String {
        "\(kind == .feature ? "Shape" : "Start") \(count) \(count == 1 ? "run" : "runs")"
    }

    /// The caption of the bar, which says what the button does.
    public static func batchCaption(count: Int, kind: BatchKind, split: Bool) -> String {
        let them = count == 1 ? "it" : "all \(count)"
        let each = count == 1 ? "The run" : "Each run"
        switch kind {
        case .feature where split:
            return "Claude splits \(them) across the repos now. \(each) waits for a slot after you approve it."
        case .feature:
            return "Claude shapes \(them) now. \(each) waits for a slot after you approve it."
        case .chore:
            return "Loam starts \(them) now, with no goal from Claude. \(each) waits for a slot when none is free."
        }
    }

    /// The drafts of the checked items, in the order of the page. Only a shape can split.
    public static func batchDrafts(_ items: [IntakeItem], kind: BatchKind, split: Bool) -> [RunDraft] {
        items.map { item in
            var draft = RunDraft(item: item)
            if kind == .feature, split { draft.repoChoice = RunChoices.split }
            return draft
        }
    }
}
