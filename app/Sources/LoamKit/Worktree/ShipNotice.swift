import Foundation

/// A problem with `gh` that the Worktrees section explains in a neutral callout (ticket 108). The
/// rows still show the local state or the last answer of GitHub. Dismiss hides a notice until the
/// app quits (`AppModel.dismissedShipNotices`).
public enum ShipNotice: Equatable, Hashable, Sendable, CaseIterable {
    /// `gh` is not installed.
    case ghMissing
    /// `gh` is installed and signed out.
    case ghSignedOut
    /// `gh` cannot read the repo: no access, or SSO not authorized.
    case noAccess

    /// The words of the callout. When `command` is set, the callout ends with it.
    public var message: String {
        switch self {
        case .ghMissing: "Install the GitHub CLI to see pull requests. Run:"
        case .ghSignedOut: "Sign in to the GitHub CLI to see pull requests."
        case .noAccess: "The GitHub CLI cannot read this repo. Run:"
        }
    }

    /// The command that fixes the problem, which the callout shows in a monospaced face.
    public var command: String? {
        switch self {
        case .ghMissing: "brew install gh"
        case .ghSignedOut: nil
        case .noAccess: "gh auth status"
        }
    }

    /// The notice that a refresh note calls for. Nil for a note that needs no fix.
    init?(_ note: PRNote) {
        switch note {
        case .ghMissing: self = .ghMissing
        case .ghSignedOut: self = .ghSignedOut
        case .noAccess: self = .noAccess
        case .noGitHubRemote, .offline, .rateLimited, .noNote: return nil
        }
    }

    /// The notices that the rows call for, once each, in the order of the cases, without the dismissed ones.
    public static func current(for rows: [WorktreeStatus], dismissed: Set<ShipNotice>) -> [ShipNotice] {
        let wanted = Set(rows.compactMap { $0.prNote.flatMap(ShipNotice.init) })
        return allCases.filter { wanted.contains($0) && !dismissed.contains($0) }
    }
}
