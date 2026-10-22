import Foundation
import Observation

/// The state of the New worktree sheet (ticket 115): the plot it is for, the repos and the links it offers, what you
/// typed or chose, and what `loam worktree new --dry-run` said about it. `AppModel` moves it: it reads the plot, runs the
/// check after a short delay, and makes the worktree. The words come from `NewWorktreeContent`.
///
/// The Branch and the Goal take their text from the link, but only while you have not typed in the field. A field that
/// you empty takes its text from the link again. A change of the link, or of the pasted URL, fills them anew.
///
/// An answer of the check belongs to the fields that it was asked for. A change of the name, the repo or the base makes
/// the answer old. A change of the goal or the link does not: the branch stays good, Start stays on, and the seed line
/// shows the new text when the next answer is back.
@MainActor
@Observable
public final class NewWorktreeModel {
    public enum Phase: Equatable, Sendable {
        /// The plot is read: its repos and its links.
        case loading
        case ready
        /// The plot has no repo, or could not be read. The message says why.
        case failed(String)
    }

    /// The Link popup: none, a link of the plot, or a URL that you paste.
    public enum LinkChoice: Hashable, Sendable {
        case none
        case plot(String)
        case pasted
    }

    /// What the check says about the Branch field.
    public enum BranchState: Equatable, Sendable {
        /// Nothing typed. Start is off.
        case empty
        /// The check for the text in the field is not back. Start is off.
        case checking
        /// A good name for a new branch.
        case new
        /// A branch with this name exists. Loam uses it as it is, so the Base does not apply.
        case exists
        /// Not a good branch name. The text says why, in the words of the core.
        case invalid(String)
        /// The plot has the worktree already, or its folder exists. The text is the folder.
        case taken(String)
        /// The check did not run, such as when the link is gone. The text is the message of the core.
        case failed(String)
    }

    /// The state of the fields when a check starts. An answer is for the stamp that it was asked with.
    public struct Stamp: Equatable, Sendable {
        public var input: Int
        public var branch: Int
    }

    /// The arguments of one check, and of the `worktree new` after it. Equal requests have the same answer.
    public struct Request: Equatable, Sendable {
        public var plot: String
        public var repo: String
        public var name: String
        /// The base that you chose. Nil takes the default base of the repo.
        public var base: String?
        public var goal: String?
        /// The ID of a link of the plot, or the URL of an issue.
        public var link: String?
    }

    /// The plot that the sheet is for. Nil while the sheet is closed.
    public private(set) var plotID: String?
    public private(set) var phase = Phase.loading
    /// Counts the opens, so the view can take the keys on each one, and a late answer of an old open is dropped.
    public private(set) var openCount = 0
    public private(set) var repos: [Repo] = []
    public private(set) var links: [PlotLink] = []
    /// The link that Start work… came from. The link card shows it. Nil when the sheet opens from "+".
    public private(set) var startLink: PlotLink?
    public private(set) var repoID: String?
    public private(set) var branch = ""
    public private(set) var goal = ""
    public private(set) var linkChoice = LinkChoice.none
    public private(set) var pastedURL = ""
    /// The base that you chose. Nil is the default base of the repo.
    public private(set) var baseChoice: String?
    /// The bases of the last answer, the default first.
    public private(set) var bases: [String] = []
    /// The default base of the last answer, such as origin/main. Empty when the repo has none.
    public private(set) var defaultBase = ""
    /// The seed line of the last answer for a good name. Nil for an empty or a bad name.
    public private(set) var seedLine: String?
    /// "What the seed adds" is open.
    public var showsSeed = false
    /// The worktree is made now. The fields lock, and Cancel is off.
    public private(set) var isStarting = false
    /// What went wrong when the worktree was made, in the words of the core. The sheet shows it in a `rust` callout.
    public private(set) var startError: String?
    /// Counts the changes of all fields.
    public private(set) var inputRevision = 0
    /// Counts the changes of the name, the repo and the base: the fields that the answer about the branch is for.
    public private(set) var branchRevision = 0
    /// Return came while Start had to wait for the plot or the check. The start runs when the answer is back, and any
    /// change of a field takes it back.
    public private(set) var startQueued = false
    /// How long the check waits after the last change. Tests make it short.
    @ObservationIgnored public var checkDelay = Duration.milliseconds(250)
    /// The check that waits or runs now. Tests wait for it.
    @ObservationIgnored var checking: Task<Void, Never>?
    /// The read of the plot that runs now.
    @ObservationIgnored var reading: Task<Void, Never>?
    /// Called after each change of a field, so `AppModel` runs the check again.
    @ObservationIgnored var onInput: (() -> Void)?
    /// Called when the sheet opens or closes. An open while it is open calls nothing.
    @ObservationIgnored public var onOpenChange: ((Bool) -> Void)?

    /// The stamp of the fields as they are now.
    public var stamp: Stamp { Stamp(input: inputRevision, branch: branchRevision) }

    private enum Outcome: Equatable {
        case result(WorktreeCheck)
        case failed(String)
    }

    @ObservationIgnored private var branchEdited = false
    @ObservationIgnored private var goalEdited = false
    private var answer: (stamp: Stamp, outcome: Outcome)?

    public init() {}

    public var isOpen: Bool { plotID != nil }

    /// True while open number `count` is the open that shows.
    func isCurrent(_ count: Int) -> Bool { plotID != nil && count == openCount }

    // MARK: Open and close

    /// `link` is the link of Start work…, or nil for the plus. The fields take their text from it at once.
    func open(plot: String, link: PlotLink?) {
        let wasOpen = isOpen
        plotID = plot
        openCount += 1
        phase = .loading
        repos = []
        links = []
        startLink = link
        repoID = nil
        branch = ""
        goal = ""
        branchEdited = false
        goalEdited = false
        linkChoice = link.map { .plot($0.id) } ?? .none
        pastedURL = ""
        baseChoice = nil
        bases = []
        defaultBase = ""
        seedLine = nil
        showsSeed = false
        isStarting = false
        startError = nil
        answer = nil
        startQueued = false
        inputRevision += 1
        branchRevision += 1
        checking?.cancel()
        checking = nil
        reading?.cancel()
        reading = nil
        fill()
        if !wasOpen { onOpenChange?(true) }
    }

    func close() {
        guard isOpen else { return }
        plotID = nil
        isStarting = false
        startQueued = false
        checking?.cancel()
        checking = nil
        reading?.cancel()
        reading = nil
        onOpenChange?(false)
    }

    /// The plot came back. The main repo is the default repo, and a plot with no repo cannot have a worktree.
    func loaded(_ plot: Plot) {
        repos = plot.repos
        links = plot.links
        guard let repo = plot.repos.first(where: \.main) ?? plot.repos.first else {
            phase = .failed("The plot has no repo. Add a repo first.")
            return
        }
        repoID = repo.id
        phase = .ready
        fill()
        // The plot is not a change that you made, so a Return that waits for it stays.
        changed(keepingQueue: true)
    }

    func failedToLoad(_ message: String) {
        phase = .failed(message)
        startQueued = false
    }

    // MARK: Fields

    public func chooseRepo(_ id: String) {
        guard repoID != id, repos.contains(where: { $0.id == id }) else { return }
        repoID = id
        // The bases belong to the repo.
        baseChoice = nil
        bases = []
        defaultBase = ""
        branchRevision += 1
        changed()
    }

    /// What you typed in the Branch field.
    public func setBranch(_ text: String) {
        guard text != branch else { return }
        branch = text
        branchEdited = !text.isEmpty
        branchRevision += 1
        changed()
    }

    /// What you typed in the Goal field.
    public func setGoal(_ text: String) {
        guard text != goal else { return }
        goal = text
        goalEdited = !text.isEmpty
        changed()
    }

    public func chooseLink(_ choice: LinkChoice) {
        guard choice != linkChoice else { return }
        linkChoice = choice
        fill()
        changed()
    }

    /// What you typed or pasted in the Link field.
    public func setPastedURL(_ text: String) {
        guard text != pastedURL else { return }
        pastedURL = text
        fill()
        changed()
    }

    /// A base from the popup. Nil is the default base.
    public func chooseBase(_ base: String?) {
        guard base != baseChoice else { return }
        baseChoice = base
        branchRevision += 1
        changed()
    }

    /// The link of the Link popup, when it is a link of the plot.
    public var chosenLink: PlotLink? {
        guard case .plot(let id) = linkChoice else { return nil }
        return links.first { $0.id == id } ?? (startLink?.id == id ? startLink : nil)
    }

    /// The issue that the link or the pasted URL names. Nil for no link and for a link that is not an issue.
    public var issue: IssueLink? {
        switch linkChoice {
        case .none: nil
        case .plot: chosenLink?.issue
        case .pasted: IssueLink(target: pastedURL)
        }
    }

    /// True when you chose to paste a URL, typed one, and it is not the URL of an issue. Start is off then.
    public var pastedURLIsWrong: Bool {
        linkChoice == .pasted && !pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && issue == nil
    }

    /// True while the Branch field has the name that the link gave.
    public var branchComesFromLink: Bool { !branchEdited && !branch.isEmpty }

    /// The goal is over the soft limit of 20 words.
    public var goalWarning: String? { WorktreeGoal.warning(for: goal) }

    /// Fills the fields that you did not type from the link.
    private func fill() {
        var name = "", text = ""
        switch linkChoice {
        case .none: break
        case .plot:
            if let link = chosenLink, let issue = link.issue {
                name = StartWorkNames.branch(label: link.label, issue: issue)
                text = StartWorkNames.goal(label: link.label, issue: issue)
            }
        case .pasted:
            // A URL has no label, so only the key gives a name.
            if let issue = IssueLink(target: pastedURL) { name = StartWorkNames.branch(label: "", issue: issue) }
        }
        // A new name is a new question for the check. The same name is not.
        if !branchEdited, branch != name {
            branch = name
            branchRevision += 1
        }
        if !goalEdited { goal = text }
    }

    // MARK: Check

    /// The arguments of the check and of `worktree new`. Nil until the plot is read.
    public var request: Request? {
        guard phase == .ready, let plotID, let repoID else { return nil }
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        var link: String?
        switch linkChoice {
        case .none: break
        case .plot(let id): link = id
        case .pasted: if issue != nil { link = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return Request(plot: plotID, repo: repoID, name: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                       base: baseChoice, goal: text.isEmpty ? nil : text, link: link)
    }

    /// The request of `worktree new`: the same fields, but no base for a branch that exists, since the core refuses it.
    public var startRequest: Request? {
        guard var request else { return nil }
        if branchState == .exists { request.base = nil }
        return request
    }

    /// An answer for the name, the repo and the base as they are now. An answer for a goal or a link that is older still
    /// counts for the branch, and its seed line stands until the next answer.
    func checked(_ result: WorktreeCheck, stamp: Stamp) {
        guard stamp.branch == branchRevision else { return }
        answer = (stamp, .result(result))
        bases = result.bases
        defaultBase = result.defaultBase
        seedLine = result.seedLine
    }

    func checkFailed(_ message: String, stamp: Stamp) {
        guard stamp.branch == branchRevision else { return }
        answer = (stamp, .failed(message))
        seedLine = nil
    }

    /// The words of the core for a name that starts with a hyphen. The core refuses it, and `loam` would read it as a
    /// flag, so it never goes to the core.
    static func hyphenProblem(_ name: String) -> String { "\"\(name)\" is not a good worktree name. Use a branch name" }

    public var branchState: BranchState {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        if name.hasPrefix("-") { return .invalid(Self.hyphenProblem(name)) }
        guard let answer, answer.stamp.branch == branchRevision else { return .checking }
        switch answer.outcome {
        // A failure may be about the link or the goal, so it holds only for the fields that it was asked for.
        case .failed(let message): return answer.stamp.input == inputRevision ? .failed(message) : .checking
        case .result(let check):
            if !check.validName { return .invalid(check.nameError ?? "This is not a good branch name.") }
            if check.worktreeExists { return .taken(check.folder) }
            return check.branchExists ? .exists : .new
        }
    }

    /// Start session can run: the plot is read, the branch is good, and no check or start is under way.
    public var canStart: Bool {
        guard phase == .ready, !isStarting, !pastedURLIsWrong else { return false }
        switch branchState {
        case .new, .exists: return true
        case .empty, .checking, .invalid, .taken, .failed: return false
        }
    }

    private func changed(keepingQueue: Bool = false) {
        inputRevision += 1
        startError = nil
        if !keepingQueue { startQueued = false }
        onInput?()
    }

    // MARK: Start

    func beginStarting() {
        isStarting = true
        startQueued = false
        startError = nil
    }

    /// Return came, and Start cannot run yet. The start waits when the plot is read or the check runs, and is then queued,
    /// so Return is never a key that does nothing. A name, a worktree or a URL that is wrong needs no wait: its note is
    /// on the sheet. Returns true when the start is queued.
    @discardableResult
    func queueStart() -> Bool {
        guard isOpen, !isStarting, !pastedURLIsWrong else { return false }
        if case .failed = phase { return false }
        guard branchState == .checking else { return false }
        startQueued = true
        return true
    }

    /// True once when a start is queued. The caller starts then, if the answer allows it.
    func takeQueuedStart() -> Bool {
        defer { startQueued = false }
        return startQueued
    }

    /// The worktree was not made. The sheet stays open, with the message.
    func startFailed(_ message: String) {
        isStarting = false
        startError = message
    }
}
