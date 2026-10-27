import Foundation

/// A place that the intake of a plot comes from: a GitHub repo of the plot, or a map in its links.
public struct IntakeSource: Codable, Equatable, Sendable {
    /// linear, github, or map.
    public var kind: String
    /// The repo, such as example/widgets, or the label of the Linear or map link.
    public var label: String
    /// Why the core could not read the source, or empty.
    public var error: String
}

/// One open issue or map ticket that a run can start from.
public struct IntakeItem: Codable, Equatable, Sendable, Identifiable {
    /// linear, github, or map.
    public var source: String
    /// ENG-523, #48, owner/repo#48, or map 135.
    public var key: String
    public var title: String
    /// For a person to read: the Linear state, such as Todo, Open, or Blocked by 135.
    public var status: String
    /// The Linear priority, such as High, or empty.
    public var priority: String
    public var labels: [String]
    /// The web page of an issue, or the path of a ticket file.
    public var url: String
    /// The last change on GitHub, or empty for a ticket.
    public var updatedAt: String
    /// The newest run that started from the item, or empty.
    public var runID: String
    public var id: String { url }
    public var isTicket: Bool { source == "map" }
    enum CodingKeys: String, CodingKey {
        case source, key, title, status, priority, labels, url
        case updatedAt = "updated_at", runID = "run_id"
    }
}

/// Output of `loam intake list`.
public struct IntakeList: Codable, Equatable, Sendable {
    public var plotID: String
    public var sources: [IntakeSource]
    public var items: [IntakeItem]
    enum CodingKeys: String, CodingKey { case sources, items, plotID = "plot_id" }
}

/// The person of a Linear API key.
public struct LinearViewer: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var organization: String
}

/// Output of `loam linear status`, `key set`, and `key rm`.
public struct LinearStatus: Codable, Equatable, Sendable {
    /// True when a key is stored.
    public var connected: Bool
    /// Nil with no key, or when Linear did not answer.
    public var viewer: LinearViewer?
    /// Why Linear did not answer a stored key, or empty.
    public var error: String
}
