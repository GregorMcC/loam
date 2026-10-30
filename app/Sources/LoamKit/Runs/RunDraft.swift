import Foundation

/// What `loam run start` needs to start a run from an intake item (ticket 204).
public struct RunDraft: Equatable, Sendable {
    public var title: String
    public var goal = ""
    public var checks: [RunCheck] = []
    public var maxTries = RunDraft.defaultTries
    /// The issue URL for `--link`, or nil.
    public var link: String?
    /// The ticket file for `--ticket`, or nil.
    public var ticket: String?
    /// The branch for `--base`, or nil for the default branch of origin (TAS-21).
    public var base: String?
    /// True when you saw the setup command of the repo and start the run with it.
    public var approveSetup = false
    /// The model for `--model`, or "" for the plot default.
    public var model = ""
    /// The level for `--effort`, or "" for the plot default.
    public var effort = ""
    /// The repo for `--repo`, or nil for the main repo. A GitHub issue starts on its own repo.
    public var repo: String?
    /// True to have Claude split the issue across the repos of the plot (`run shape --split`). Shape only.
    public var split = false
    /// The landed run that the new run fixes, for `--fixes`, or nil (TAS-176).
    public var fixes: String?

    /// The value of the Repo picker: the repo, or `RunChoices.split`.
    public var repoChoice: String {
        get { split ? RunChoices.split : repo ?? "" }
        set {
            split = newValue == RunChoices.split
            repo = split ? nil : newValue
        }
    }

    /// The tries of a new run.
    public static let defaultTries = 3

    /// A draft of a run that fixes a landed run: the issue and the repo of that run, and `--fixes` with its ID.
    public init(fixing run: Run) {
        title = run.title.hasPrefix("Fix: ") ? run.title : "Fix: \(run.title)"
        switch run.source?.kind {
        case "map": ticket = run.source?.url
        case "linear", "github": link = run.source?.url
        default: break
        }
        repo = run.shape.flatMap { $0.repo.isEmpty ? nil : $0.repo }
        fixes = run.id
    }

    /// A draft that starts from the item: an issue gives `--link`, a map ticket gives `--ticket`.
    public init(item: IntakeItem) {
        title = item.title
        if item.isTicket { ticket = item.url } else { link = item.url }
        repo = item.repo.isEmpty ? nil : item.repo
    }
}
