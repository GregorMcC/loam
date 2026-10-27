import Foundation

/// A check that every run of a plot must pass (ticket 209), such as "Views use the colour tokens". The gate runs it
/// as the check "Rule: <name>", after the checks of the run.
public struct Rule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var plotID: String
    public var name: String
    /// A shell command in the folder of the run. The rule holds when it exits 0.
    public var command: String
    /// The note that the rule came from, or empty.
    public var note: String
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, command, note
        case plotID = "plot_id", createdAt = "created_at"
    }
}

/// Output of `loam rule add` and `loam rule rm`.
public struct RuleOne: Codable, Equatable, Sendable {
    public var rule: Rule
}

/// Output of `loam rule list`.
public struct RuleList: Codable, Equatable, Sendable {
    public var rules: [Rule]
}

/// A note that you sent back is like a note that you sent back on another run of the plot, so it can become a rule.
public struct RuleOffer: Codable, Equatable, Sendable {
    /// The text of the note, without its file and line.
    public var note: String
    /// The text of the note like it.
    public var earlier: String
    public var earlierRunID: String
    public var earlierTitle: String

    enum CodingKeys: String, CodingKey {
        case note, earlier
        case earlierRunID = "earlier_run_id", earlierTitle = "earlier_title"
    }
}
