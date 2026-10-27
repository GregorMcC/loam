import Foundation

/// A place that the intake of a plot comes from: a GitHub repo of the plot, or a map in its links.
public struct IntakeSource: Codable, Equatable, Sendable {
    /// github or map.
    public var kind: String
    /// The repo, such as example/widgets, or the label of the map link.
    public var label: String
    /// Why the core could not read the source, or empty.
    public var error: String
}

/// One open issue or map ticket that a run can start from.
public struct IntakeItem: Codable, Equatable, Sendable, Identifiable {
    /// github or map.
    public var source: String
    /// #48, owner/repo#48, or map 135.
    public var key: String
    public var title: String
    /// For a person to read: Open, or Blocked by 135.
    public var status: String
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
        case source, key, title, status, labels, url
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
