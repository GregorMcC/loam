import Foundation

/// Where a tab lives: in a plot, or in Home (ticket 99). Home holds the tabs that belong to no
/// plot. It is not a plot: the core does not know it, and it has no brief, repos, or worktrees.
/// The order is Home first, then the plots by ID.
public enum Space: Hashable, Comparable, Codable, Sendable {
    case home
    case plot(String)

    /// The plot ID, or nil for Home.
    public var plotID: String? {
        if case .plot(let id) = self { id } else { nil }
    }

    public var isHome: Bool { self == .home }

    /// The name of Home in the sidebar, the title bar, the switcher, and a banner.
    public static let homeName = "Home"
}
