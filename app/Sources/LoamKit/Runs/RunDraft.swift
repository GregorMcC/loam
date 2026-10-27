import Foundation

/// What `loam run start` needs to start a run from an intake item (ticket 204).
public struct RunDraft: Equatable, Sendable {
    public var title: String
    public var goal = ""
    public var checks: [RunCheck] = []
    public var maxTries = 3
    /// The issue URL for `--link`, or nil.
    public var link: String?
    /// The ticket file for `--ticket`, or nil.
    public var ticket: String?
    /// The branch for `--base`, or nil for the default branch of origin (TAS-21).
    public var base: String?
    /// True when you saw the setup command of the repo and start the run with it.
    public var approveSetup = false

    /// A draft that starts from the item: an issue gives `--link`, a map ticket gives `--ticket`.
    public init(item: IntakeItem) {
        title = item.title
        if item.isTicket { ticket = item.url } else { link = item.url }
    }
}
