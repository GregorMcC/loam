import Foundation

/// The items of the window toolbar that act (ticket 126).
public enum ToolbarAction: CaseIterable, Sendable {
    case toggleSidebar
    /// "N elsewhere need you".
    case needsYou
    case newSession
    case plotPanel
}

extension AppModel {
    /// True while a sheet shows over the window: the Land sheet or the New worktree sheet. Its scrim covers the title bar
    /// then, as the dim of a native sheet does.
    public var sheetIsOpen: Bool { landSheet.isOpen || newWorktreeSheet.isOpen }

    /// True while a sheet shows or holds the window (`sheetHoldsWindow`). The window behind it must not change then.
    public var sheetBlocksWindow: Bool { sheetIsOpen || sheetHoldsWindow }

    /// Whether a toolbar item takes a click. None does while a sheet shows or holds the window: the scrim covers the toolbar,
    /// and a click there would change the window under the sheet (a new tab, the panel, the sidebar or the plot). Home has no
    /// plot panel (ticket 99).
    public func toolbarAllows(_ action: ToolbarAction) -> Bool {
        guard !sheetBlocksWindow else { return false }
        return action != .plotPanel || workspace.activePlotID != nil
    }

    /// Whether a command runs now. While a sheet shows or holds the window, only the commands of the app run (ticket 128). A
    /// menu item, a fixed key and a Ghostty action all ask this, so a key does what its menu item does. `nativeSheetShows` is
    /// true while a native sheet is on the window (the close question, the Ghostty config errors, the plot name dialog): the
    /// window controller knows it, and the rule is the same.
    public func commandAllowed(_ command: AppCommand, nativeSheetShows: Bool = false) -> Bool {
        !command.actsOnWindow || !(sheetBlocksWindow || nativeSheetShows)
    }
}
