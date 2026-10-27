import AppKit
import LoamKit

/// The window buttons while a sheet of Loam shows or holds the window (ticket 133). A native sheet turns the close button off
/// for its window and takes away full screen, so a click on the green button zooms the window. The minimize button, an
/// Option-click on the green button and a double click on the title bar work as before. A sheet of Loam is a view in the window,
/// so the window has to do the same.
extension MainWindow {
    /// Sets the close button and full screen from `sheetBlocksWindow`. A native sheet on the window answers off for the close
    /// button while it shows, whatever this sets. The state that this sets shows again when that sheet ends. Loam sets no other
    /// full screen behaviour, so `.fullScreenNone` is the only bit that this changes.
    func syncWindowButtons() {
        let blocked = sheetBlocksWindow()
        standardWindowButton(.closeButton)?.isEnabled = !blocked
        // A window that is full screen keeps its behaviour. The change could leave it with no way out.
        if !blocked {
            collectionBehavior.remove(.fullScreenNone)
        } else if !styleMask.contains(.fullScreen) {
            collectionBehavior.insert(.fullScreenNone)
        }
    }
}

extension MainWindowController {
    /// Sets the window buttons from `AppModel.sheetBlocksWindow`. This value changes only when a sheet opens or closes: a
    /// merge or a start holds a sheet that is open. So `syncTitleBarScrim` calls this at each of them.
    func syncWindowButtons() {
        (window as? MainWindow)?.syncWindowButtons()
    }

    /// Full screen brings the window buttons again, and a window in full screen keeps its behaviour. So each end of full screen
    /// sets them again.
    func windowDidEnterFullScreen(_ notification: Notification) { syncWindowButtons() }
    func windowDidExitFullScreen(_ notification: Notification) { syncWindowButtons() }
}
