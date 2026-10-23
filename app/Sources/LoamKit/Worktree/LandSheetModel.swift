import Foundation
import Observation

/// The state of the Land sheet (ticket 112): the worktree it lands, the plan from `loam worktree land --dry-run`,
/// what you chose (the method, the three boxes, the Where it stands text), and whether a merge runs. `AppModel`
/// moves it: it reads the plan, runs the merge, and closes the sheet. The words come from `LandSheetContent`.
@MainActor
@Observable
public final class LandSheetModel {
    public enum Phase: Equatable, Sendable {
        /// The dry run runs. The checklist shows a spinner.
        case loading
        case plan(LandResult)
        /// The dry run failed, such as when `gh` is signed out. The message says why.
        case failed(String)
    }

    /// The worktree that the sheet lands. Nil while the sheet is closed.
    public private(set) var worktreeID: String?
    public private(set) var phase = Phase.loading
    /// Counts the opens, so the view can take the keys on each one, and a late answer of an old open is dropped.
    public private(set) var openCount = 0
    /// The method that you chose. Nil takes the default of the plan.
    public var method: MergeMethod?
    /// The first box: close the panes and remove the worktree. Off passes `--keep-worktree`.
    public var removesWorktree = true
    /// The second box: delete the branch on GitHub. Off passes `--keep-remote-branch`.
    public var deletesBranch = true
    /// The third box: save Where it stands after the merge.
    public var movesWhereItStandsOn = true
    /// The text of the box under the third checkbox. It starts as the sentence about the merge, then the text of the plot.
    public var whereText = ""
    /// The first sentence of `whereText`, which the box selects when it takes the keys.
    public private(set) var whereSentence = ""
    /// The version of Where it stands when the sheet read it. The save expects it, so a change meanwhile is not lost.
    public private(set) var whereVersion: Int?
    /// A merge runs. The checklist locks, and Cancel is off.
    public private(set) var isMerging = false {
        didSet {
            guard oldValue, !isMerging else { return }
            let waiting = mergeEndWaiters
            let failed = lastMergeFailed
            mergeEndWaiters = []
            for body in waiting { body(failed) }
        }
    }
    /// Update branch runs.
    public private(set) var isUpdating = false
    /// What went wrong, in the words of the core or of GitHub. The sheet shows it in a `rust` callout.
    public private(set) var landError: String?
    /// The read of the plan that runs now. Tests wait for it.
    @ObservationIgnored var reading: Task<Void, Never>?
    @ObservationIgnored private var mergeEndWaiters: [(Bool) -> Void] = []
    /// The last merge ended with a message of GitHub or of the core.
    @ObservationIgnored private var lastMergeFailed = false
    /// Called when the sheet opens or closes. An open while it is open calls nothing, and the window takes the keys on
    /// the first one only.
    @ObservationIgnored public var onOpenChange: ((Bool) -> Void)?

    public init() {}

    public var isOpen: Bool { worktreeID != nil }

    /// The plan, when the dry run is back.
    public var plan: LandResult? {
        if case .plan(let plan) = phase { plan } else { nil }
    }

    // MARK: Moves

    func open(_ worktree: String) {
        let wasOpen = isOpen
        worktreeID = worktree
        openCount += 1
        phase = .loading
        method = nil
        removesWorktree = true
        deletesBranch = true
        movesWhereItStandsOn = true
        whereText = ""
        whereSentence = ""
        whereVersion = nil
        isMerging = false
        isUpdating = false
        landError = nil
        reading?.cancel()
        reading = nil
        if !wasOpen { onOpenChange?(true) }
    }

    func close() {
        guard isOpen else { return }
        worktreeID = nil
        phase = .loading
        isMerging = false
        isUpdating = false
        landError = nil
        reading?.cancel()
        reading = nil
        onOpenChange?(false)
    }

    /// Runs `body` once the merge ends, however it ends. Its argument says whether the merge failed: it did not happen, and
    /// the sheet shows the message. Done, and cancelled with the question about a session in a turn, are not failures. At
    /// once, with false, when no merge runs. Quit uses it, since a merge on GitHub cannot be undone, and an app that quits
    /// in the middle can leave it half done.
    public func whenMergeEnds(_ body: @escaping (_ failed: Bool) -> Void) {
        if isMerging { mergeEndWaiters.append(body) } else { body(false) }
    }

    /// True while open number `count` is the open that shows.
    func isCurrent(_ count: Int) -> Bool { worktreeID != nil && count == openCount }

    /// The plan came back. The first read also gives the Where it stands text; a read after Update branch keeps
    /// what you typed.
    func loaded(_ plan: LandResult, where whereRead: (text: String, version: Int?)? = nil) {
        phase = .plan(plan)
        guard let whereRead else { return }
        let prefill = LandSheetContent.whereItStands(merged: plan.pr.number, title: plan.pr.title, current: whereRead.text)
        whereText = prefill.text
        whereSentence = prefill.sentence
        whereVersion = whereRead.version
    }

    func failed(_ message: String) {
        phase = .failed(message)
    }

    /// The plan is read again, such as after the core stopped a merge. Until the new plan is back there is no plan, so
    /// Merge cannot run on the old one.
    func readingAgain() {
        phase = .loading
    }

    func beginMerging() {
        lastMergeFailed = false
        isMerging = true
        landError = nil
    }

    /// The merge stopped with no error, such as when you cancel the question about a session in a turn.
    func endMerging() {
        isMerging = false
    }

    /// The merge did not happen. The sheet stays open, with the message.
    func mergeFailed(_ message: String) {
        lastMergeFailed = true
        isMerging = false
        landError = message
    }

    /// A problem that is not a merge: a row button that does not match, for example.
    func showError(_ message: String) {
        landError = message
    }

    func beginUpdating() {
        isUpdating = true
        landError = nil
    }

    func endUpdating(error: String? = nil) {
        isUpdating = false
        if let error { landError = error }
    }

    /// The method that the merge uses: your choice when the plan allows it, else the default of the plan.
    public func effectiveMethod(for content: LandSheetContent) -> MergeMethod? {
        content.mergeQueue ? nil : method.flatMap { content.mergeMethods.contains($0) ? $0 : nil } ?? content.defaultMethod
    }
}
