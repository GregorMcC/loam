import AppKit
import LoamKit
import SwiftUI

/// The window side of the New worktree sheet (ticket 115): the overlay and the keys while it shows.
extension MainWindowController {
    func installNewWorktreeSheet() {
        let host = NSHostingView(rootView: NewWorktreeSheetView(app: model))
        host.sizingOptions = []
        host.isHidden = true
        newWorktreeHost = host
        (splitController.splitView as? LoamSplitView)?.install(newWorktreeSheet: host)
        model.newWorktreeSheet.onOpenChange = { [weak self] open in self?.newWorktreeSheetChanged(open: open) }
    }

    private func newWorktreeSheetChanged(open: Bool) {
        newWorktreeHost.isHidden = !open
        syncTitleBarScrim()
        guard open else { return focusActivePane() }
        // One overlay at a time: the switcher, the actions menu, the PR popover and the Land sheet would take the clicks.
        if model.switcher.isOpen { model.switcher.close() }
        closeActionsMenu()
        model.closePullRequest()
        model.closeLandSheet()
        window?.makeFirstResponder(newWorktreeHost)
    }
}

extension LoamSplitView {
    /// Adds the New worktree sheet over the Land sheet and under the switcher, in the superview of the split view.
    func install(newWorktreeSheet view: NSView) {
        newWorktreeSheet = view
        superview?.addSubview(view, positioned: .above, relativeTo: sheet)
        needsLayout = true
    }
}
