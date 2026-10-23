import AppKit
import LoamKit

/// The keys that a field of the plot panel held when the PR popover opened. The popover takes the keys
/// for Escape and Return, and gives them back to the field, with its caret or selection, when it closes.
struct HeldKeys {
    weak var responder: NSResponder?
    var selection: NSRange?
}

/// Where the open PR popover points, in the space of its overlay (the origin is the top left corner). The
/// window measures the control of the popover after each open and after each layout pass of the split view,
/// so the card follows the control when the window, a divider or a column moves it.
@MainActor @Observable
final class PopoverPlace {
    var anchor = CGRect.zero
}

/// The window side of the PR popover (ticket 109): showing the overlay, the keys while it shows, and the
/// place that it opens from.
extension MainWindowController {
    func pullRequestPopoverChanged(open: Bool) {
        popoverHost.isHidden = !open
        guard open else { return giveKeysBackFromPopover() }
        // One overlay at a time: the switcher and the actions menu would take the clicks.
        if model.switcher.isOpen { model.switcher.close() }
        closeActionsMenu()
        let workspace = model.workspace
        popoverContext = ActionsContext(space: workspace.activeSpace, pane: workspace.focusedPane)
        keysBeforePopover = keysHeldInPanel()
        window?.makeFirstResponder(popoverHost)
    }

    /// The popover names a worktree, and the pane that you work in leads the keys. When the focus moves
    /// (⌘2, a new session, a click in the sidebar), the popover closes, so Escape and the keys of the
    /// new pane do not go to a popover that you left.
    func closePullRequestIfContextChanged() {
        guard model.prPopover.isOpen else { return }
        let workspace = model.workspace
        if popoverContext != ActionsContext(space: workspace.activeSpace, pane: workspace.focusedPane) { model.closePullRequest() }
    }

    /// Return on the primary button, or a click on it. The three Send buttons type the prompt into the session
    /// of the worktree, copy it, or start a session (ticket 110). No Land… button shows until ticket 112 builds it
    /// (`PRPrimaryAction.built`).
    func runPrimaryAction(_ action: PRPrimaryAction) {
        switch action {
        case .sendFailures, .sendReview, .sendConflicts:
            guard let id = model.prPopover.worktreeID else { return }
            model.sendToSession(id)
        case .land:
            assertionFailure("The primary button \(action) shows before its ticket is built")
        }
    }

    // MARK: Place

    /// Places the open popover at its control again: after each open, and after each layout pass of the
    /// split view (a resize of the window, a drag of a divider, the sidebar or the plot panel that shows or
    /// hides). A control that is gone closes the popover, such as a row of a column that hid.
    func placePullRequestPopover() {
        guard model.prPopover.isOpen else { return }
        guard let rect = popoverAnchorRect() else { return model.closePullRequest() }
        if popoverPlace.anchor != rect { popoverPlace.anchor = rect }
    }

    /// The rectangle that the open popover opens from, in the space of its overlay (the origin is the top
    /// left corner). A clicked control says where it is now. The chip, a key, ⌘⇧L or the switcher give the
    /// chip of the action bar, else the left end of the bar. The chip is the PR of the focused pane, so a
    /// popover of another worktree does not point at it. Nil when the control is gone.
    private func popoverAnchorRect() -> CGRect? {
        let windowRect: CGRect
        switch model.prPopover.anchor {
        case .control(let control):
            guard let rect = control.windowRect else { return nil }
            windowRect = rect
        case .actionBar:
            let leadsToChip = model.focusedWorktree?.id == model.prPopover.worktreeID
            windowRect = leadsToChip ? chipProbe.windowRect ?? barLeadingRect : barLeadingRect
        }
        // SwiftUI lays the popover out inside the safe area of its host, so its origin is the corner of that area.
        let safe = topLeft(popoverHost.safeAreaRect)
        return topLeft(popoverHost.convert(windowRect, from: nil)).offsetBy(dx: -safe.minX, dy: -safe.minY)
    }

    /// The rectangle with the origin in the top left corner of the popover host, whichever way the host counts y.
    private func topLeft(_ rect: CGRect) -> CGRect {
        popoverHost.isFlipped ? rect : CGRect(x: rect.minX, y: popoverHost.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The left end of the action bar, in the window. A popover that no chip leads to stands over it.
    private var barLeadingRect: CGRect {
        let bar = barHost.convert(barHost.bounds, to: nil)
        return CGRect(x: bar.minX + ActionBarView.leadingInset, y: bar.minY, width: 0, height: bar.height)
    }

    // MARK: Keys

    /// The field of the plot panel that holds the keys now, with its selection. Nil when the keys are in
    /// the terminal or anywhere else: the focused pane takes them back.
    private func keysHeldInPanel() -> HeldKeys? {
        guard let holder = window?.firstResponder as? NSView, holder.isDescendant(of: panelController.view) else { return nil }
        guard let text = holder as? NSTextView else { return HeldKeys(responder: holder, selection: nil) }
        // The field editor stands in for its text field.
        let owner = text.isFieldEditor ? (text.delegate as? NSView) ?? text : text
        return HeldKeys(responder: owner, selection: text.selectedRange)
    }

    /// The popover closed. The keys go back to the field of the panel that had them, else to the focused pane.
    /// A field of a panel that hid, or hides now, gets no keys.
    private func giveKeysBackFromPopover() {
        popoverContext = nil
        defer { keysBeforePopover = nil }
        guard let window, let held = keysBeforePopover, let responder = held.responder as? NSView, responder.window === window,
              !responder.isHiddenOrHasHiddenAncestor, !responder.visibleRect.isEmpty,
              window.makeFirstResponder(responder) else { return focusActivePane() }
        guard let selection = held.selection else { return }
        let editor = (responder as? NSTextView) ?? window.fieldEditor(false, for: responder) as? NSTextView
        editor?.selectedRange = selection
    }
}
