import Foundation

/// One row of "What each plot reads": the plot, the Linear scope of its links, and the labels of those links.
public struct PlotScopeRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let plot: String
    /// The team or project of each Linear link, or "None".
    public let scope: String
    /// The label of each Linear link that gives a scope, or "No Linear link".
    public let source: String
    public var hasScope: Bool { scope != Self.noScope }

    static let noScope = "None"
    static let noLink = "No Linear link"

    public init(id: String, plot: String, scope: String, source: String) {
        self.id = id
        self.plot = plot
        self.scope = scope
        self.source = source
    }

    /// One row for each plot that is not archived. The scope of a link follows `ParseScope` in the core: a team page
    /// or a project page. Any other Linear link gives no scope.
    public static func rows(plots: [Plot]) -> [PlotScopeRow] {
        plots.filter { !$0.archived }.map { plot in
            let scoped = plot.links.compactMap { link in scopeWords(target: link.target).map { (link, $0) } }
            guard !scoped.isEmpty else { return PlotScopeRow(id: plot.id, plot: plot.name, scope: noScope, source: noLink) }
            return PlotScopeRow(
                id: plot.id, plot: plot.name,
                scope: scoped.map(\.1).joined(separator: " \u{B7} "),
                source: scoped.map { $0.0.label.isEmpty ? $0.0.target : $0.0.label }.joined(separator: ", "))
        }
    }

    /// "ENG team" for a team page, "Loam redesign project" for a project page, or nil for any other target.
    static func scopeWords(target: String) -> String? {
        guard let url = URL(string: target.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.host()?.lowercased() == "linear.app" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        switch parts[1] {
        case "team":
            return "\(parts[2].uppercased()) team"
        case "project":
            // The slug ends with the short ID of the project: "loam-redesign-8f3a2b1c9d0e".
            var words = parts[2].split(separator: "-").map(String.init)
            if words.count > 1 { words.removeLast() }
            let name = words.joined(separator: " ")
            return "\(name.prefix(1).uppercased() + name.dropFirst()) project"
        default:
            return nil
        }
    }
}
