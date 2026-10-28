import AppKit

/// Menus in the driver (ticket 113). A press that opens a menu goes on the event queue, so the scenario goes on while
/// AppKit tracks the menu. An app in the background takes no keys in a menu, so the items take the accessibility API,
/// as VoiceOver uses it.
@MainActor
extension DriverApp {
    /// The windows of the menus of the app that are open.
    func openMenuWindows() -> Int {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return listed.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) >= level
        }.count
    }

    /// The item with this title in a menu of the app that is open, through the accessibility API.
    func openMenuItem(_ title: String) throws -> AXUIElement {
        func string(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? String ?? ""
        }
        var queue = [AXUIElementCreateApplication(getpid())]
        var visited = 0
        while !queue.isEmpty, visited < 20_000 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == kAXMenuItemRole as String, string(element, kAXTitleAttribute) == title {
                return element
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                queue += (children as? [AXUIElement]) ?? []
            }
        }
        throw DriverFailure("no open menu has the item \(title)")
    }

    /// The point in the window at the middle of the element `id`. It is nil until the element stands in the window.
    func windowPoint(of id: String) -> NSPoint? {
        // The accessibility frame has its origin at the top left of the main screen, AppKit at the bottom left.
        guard let frame = AccessibilityProbe.shared.node(id)?.frame, let screen = NSScreen.screens.first else { return nil }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: screen.frame.height - frame.midY))
        return window.contentView?.bounds.contains(point) == true ? point : nil
    }

    /// Opens the pop-up menu of the element `id`, as a click does, and waits until it shows (TAS-44).
    func openMenu(of id: String) async throws {
        AccessibilityProbe.shared.rescan()
        try await waitUntil("\(id) stands in the window") { windowPoint(of: id) != nil }
        guard let point = windowPoint(of: id) else { throw DriverFailure("no element \(id)") }
        try await postMouseDown(.leftMouseDown, at: point)
        try await waitUntil("the menu of \(id) opens") { openMenuWindows() > 0 }
    }

    /// Picks the item with this title in the menu that is open, and waits until the menu closes.
    func pickMenuItem(_ title: String) async throws {
        guard AXUIElementPerformAction(try openMenuItem(title), kAXPressAction as CFString) == .success else {
            throw DriverFailure("\(title) took no press")
        }
        Log.line("press menu item \(title)")
        try await waitUntil("the menu closes") { openMenuWindows() == 0 }
    }
}
