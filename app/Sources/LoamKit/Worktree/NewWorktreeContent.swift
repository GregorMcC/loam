import Foundation

/// The words of the New worktree sheet (ticket 115, board NewWorktreeSheet) for the state of a `NewWorktreeModel`. The
/// view shows them as they are, so a test can say what the sheet says without a window.
public struct NewWorktreeContent: Equatable {
    /// A line under a field. A problem is `rust`, a warning is `needs`, a hint is `ink-muted`.
    public struct Note: Equatable {
        public enum Tone: Equatable { case hint, warning, problem }
        public var text: String
        public var tone: Tone
    }

    /// The card at the top when the sheet starts from a link.
    public struct LinkCard: Equatable {
        public var label: String
        public var note: String
        public var kind: LinkKind
    }

    public struct RepoItem: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var isMain: Bool
    }

    /// An entry of the Base popup. `value` is what `--base` gets, and nil is the default base.
    public struct BaseItem: Equatable {
        public var title: String
        public var value: String?
    }

    /// An entry of the Link popup that is a link of the plot.
    public struct LinkItem: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var kind: LinkKind
    }

    public static let title = "New worktree"
    public static let mainRepo = "Main repo"
    public static let goalHint = "One line. You can leave it empty."
    public static let noLink = "None"
    public static let pasteLink = "Paste a URL\u{2026}"
    public static let pasteHint = "Loam saves this link with the worktree. It does not go into the plot's links."
    public static let pasteProblem = "Paste the URL of a Linear issue or a GitHub issue."
    public static let branchExists = "A branch with this name exists. Loam uses it as it is."
    public static let seedTitle = "What the seed adds"
    public static let seedNote = "Loam adds this line to the seed of the plot."
    public static let seedWaiting = "The line shows when the branch name is good."
    public static let footer = "Loam makes the worktree and starts a seeded session in it."
    /// The first entry of the Base popup when the repo has no default base.
    public static let originDefault = "Default branch of origin"

    public let linkCard: LinkCard?
    public let repos: [RepoItem]
    public let repoName: String
    public let repoIsMain: Bool
    public let branchNote: Note?
    public let baseTitle: String
    public let baseItems: [BaseItem]
    /// A branch that exists takes no base, so the popup is off.
    public let baseApplies: Bool
    public let goalNote: Note
    public let linkTitle: String
    public let linkItems: [LinkItem]
    public let linkNote: Note?
    public let seedText: String
    public let primaryTitle: String

    @MainActor
    public init(_ model: NewWorktreeModel) {
        if let link = model.startLink {
            let note = link.issue.map { "Loam does not copy the issue. The session reads it through its \($0.connector) connector." }
            linkCard = LinkCard(label: link.label, note: note ?? "", kind: link.kind)
        } else {
            linkCard = nil
        }

        repos = model.repos.map { RepoItem(id: $0.id, name: Self.name(of: $0), isMain: $0.main) }
        let repo = model.repos.first { $0.id == model.repoID }
        repoName = repo.map(Self.name(of:)) ?? ""
        repoIsMain = repo?.main ?? false

        let state = model.branchState
        baseApplies = state != .exists
        branchNote = Self.branchNote(state, linkChoice: model.linkChoice, fromLink: model.branchComesFromLink)

        if model.defaultBase.isEmpty {
            baseTitle = model.baseChoice ?? Self.originDefault
            baseItems = [BaseItem(title: Self.originDefault, value: nil)] + model.bases.map { BaseItem(title: $0, value: $0) }
        } else {
            baseTitle = model.baseChoice ?? model.defaultBase
            // The default base is the first entry, and it is the choice of no base.
            baseItems = [BaseItem(title: model.defaultBase, value: nil)]
                + model.bases.filter { $0 != model.defaultBase }.map { BaseItem(title: $0, value: $0) }
        }

        goalNote = model.goalWarning.map { Note(text: $0, tone: .warning) } ?? Note(text: Self.goalHint, tone: .hint)

        linkItems = model.links.map { LinkItem(id: $0.id, title: $0.label, kind: $0.kind) }
        switch model.linkChoice {
        case .none:
            linkTitle = Self.noLink
            linkNote = nil
        case .plot:
            linkTitle = model.chosenLink?.label ?? Self.noLink
            linkNote = nil
        case .pasted:
            linkTitle = Self.pasteLink
            linkNote = model.pastedURLIsWrong ? Note(text: Self.pasteProblem, tone: .problem) : Note(text: Self.pasteHint, tone: .hint)
        }

        seedText = model.seedLine ?? Self.seedWaiting
        primaryTitle = model.isStarting || model.startQueued ? "Starting\u{2026}" : "Start session"
    }

    /// The name of a repo: its folder.
    static func name(of repo: Repo) -> String {
        URL(fileURLWithPath: repo.path).lastPathComponent
    }

    private static func branchNote(_ state: NewWorktreeModel.BranchState, linkChoice: NewWorktreeModel.LinkChoice,
                                   fromLink: Bool) -> Note? {
        switch state {
        case .exists: return Note(text: branchExists, tone: .problem)
        case .invalid(let reason): return Note(text: sentence(reason), tone: .problem)
        case .taken(let folder):
            return Note(text: "A worktree or a folder named \(folder) exists already.", tone: .problem)
        case .failed(let message): return Note(text: sentence(message), tone: .problem)
        case .empty, .checking, .new:
            guard fromLink else { return nil }
            return Note(text: linkChoice == .pasted ? "From the issue key." : "From the issue key and the link label.", tone: .hint)
        }
    }

    /// A message of the core as one sentence that ends in a full stop. The first letter is a capital.
    static func sentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return text }
        let capital = first.uppercased() + text.dropFirst()
        return capital.hasSuffix(".") || capital.hasSuffix("?") || capital.hasSuffix("!") ? capital : capital + "."
    }
}
