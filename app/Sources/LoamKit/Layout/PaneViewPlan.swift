import Foundation

/// The window's record of its pane views: which views to close and which to build on a render.
///
/// A pane keeps its `PaneID` when it resumes, when it starts a new session, and when its archived
/// plot comes back. The safe close of the old view takes up to 5 s (`SafeClose`). If the new view
/// starts in that time, two processes can hold the same session (ticket 61). So a pane gets no new
/// view while a close of an older view of that pane runs. When the last close of the pane finishes,
/// `onCloseFinished` runs, and the next render builds the view.
@MainActor
public final class PaneViewPlan {
    /// Runs when the last running close of a pane finishes, so the window can build its new view.
    public var onCloseFinished: ((PaneID) -> Void)?

    /// The launch count of each pane when its view was built.
    private var built: [PaneID: Int] = [:]
    /// The number of closes that run for each pane.
    private var closing: [PaneID: Int] = [:]
    /// Runs once no close runs.
    private var idleWaiters: [() -> Void] = []

    public init() {}

    /// The built panes whose view must close: the pane is gone, its plot waits, or it restarted.
    public func toClose(in workspace: Workspace) -> [PaneID] {
        let wanted = Set(workspace.livePaneIDs)
        return built.keys.filter { !wanted.contains($0) || built[$0] != workspace.launch(of: $0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// The live panes that need a view now. A pane whose older view still closes waits.
    public func toBuild(in workspace: Workspace) -> [PaneID] {
        workspace.livePaneIDs.filter { built[$0] == nil && closing[$0] == nil }
    }

    /// Records the view that the window built for the pane.
    public func didBuild(_ pane: PaneID, in workspace: Workspace) {
        built[pane] = workspace.launch(of: pane)
    }

    /// True while a close of a view of the pane runs.
    public func isClosing(_ pane: PaneID) -> Bool { closing[pane] != nil }

    /// True while any close runs.
    public var isClosingAny: Bool { !closing.isEmpty }

    /// Records the start of a close of the pane's view. The pane has no view from now on. Call the
    /// returned function when the close finishes. A second call of it does nothing.
    public func closeStarted(_ pane: PaneID) -> () -> Void {
        built[pane] = nil
        closing[pane, default: 0] += 1
        var finished = false
        return { [weak self] in
            guard !finished else { return }
            finished = true
            self?.closeFinished(pane)
        }
    }

    /// Runs `body` once no close runs: at once when none runs now.
    public func whenClosesFinish(_ body: @escaping () -> Void) {
        if closing.isEmpty { body() } else { idleWaiters.append(body) }
    }

    /// Drops the record of a view that the window no longer has, with no close.
    public func forget(_ pane: PaneID) {
        built[pane] = nil
    }

    private func closeFinished(_ pane: PaneID) {
        let left = (closing[pane] ?? 1) - 1
        closing[pane] = left > 0 ? left : nil
        if closing.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0() }
        }
        if left <= 0 { onCloseFinished?(pane) }
    }
}
