import AppKit
import LoamKit

/// The window side of the Land sheet (ticket 112): showing the overlay and the keys while it shows.
extension MainWindowController {
    func landSheetChanged(open: Bool) {
        landHost.isHidden = !open
        guard open else { return focusActivePane() }
        // One overlay at a time: the switcher, the actions menu and the PR popover would take the clicks.
        if model.switcher.isOpen { model.switcher.close() }
        closeActionsMenu()
        model.closePullRequest()
        window?.makeFirstResponder(landHost)
    }
}
