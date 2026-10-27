import AppKit
import LoamKit

/// The window buttons while a sheet of Loam shows or holds the window (ticket 133). A native sheet turns the close button off
/// for its window and takes away full screen, so a click on the green button zooms the window. The minimize button, an
/// Option-click on the green button and a double click on the title bar work as before. A sheet of Loam is a view in the window,
/// so the window has to do the same.
extension MainWindow {
    /// Sets the close button and full screen from `sheetBlocksWindow`. A native sheet on the window answers off for the close
    /// button while it shows. The state that this sets comes back when that sheet ends.
    func syncWindowButtons() {
        let blocked = sheetBlocksWindow()
        standardWindowButton(.closeButton)?.isEnabled = !blocked
        // A window that is full screen keeps its behaviour. The change could leave it with no way out.
        guard !styleMask.contains(.fullScreen) else { return }
        if blocked { collectionBehavior.insert(.fullScreenNone) } else { collectionBehavior.remove(.fullScreenNone) }
    }
}

extension MainWindowController {
    /// Sets the window buttons now, and again after each change of `AppModel.sheetBlocksWindow`.
    func observeWindowButtons() {
        withObservationTracking {
            _ = model.sheetBlocksWindow
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeWindowButtons() }
        }
        (window as? MainWindow)?.syncWindowButtons()
    }
}
