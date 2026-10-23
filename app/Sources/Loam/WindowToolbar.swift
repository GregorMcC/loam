import AppKit
import LoamKit
import Observation

/// The unified toolbar (tickets 68 and 69): the sidebar button over the sidebar, then the plot name
/// as the window title, then "N elsewhere need you" (while it applies), New session and Plot panel
/// at the right. The panel is a plain split item, not an inspector (it stands on the chrome ground,
/// not on system glass), so no tracking separator follows it. macOS 26 draws the items on glass. The toolbar sits over the frame only: the tab bar
/// and the panes start under it.
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    static let newSession = NSToolbarItem.Identifier("dev.loam.new-session")
    static let plotPanel = NSToolbarItem.Identifier("dev.loam.plot-panel")

    private let model: AppModel
    private weak var target: AnyObject?
    private let newSessionAction: Selector
    private let panelAction: Selector
    private var panelItem: NSToolbarItem?
    private var panelButton: NSButton?
    private var newSessionButton: NSButton?
    private weak var toolbar: NSToolbar?
    /// Built once with the delegate, so the toolbar can hide and show it.
    private let needsYou: NeedsYouToolbarItem

    init(model: AppModel, target: AnyObject, newSession: Selector, plotPanel: Selector) {
        self.model = model
        self.target = target
        newSessionAction = newSession
        panelAction = plotPanel
        needsYou = NeedsYouToolbarItem(model: model)
        super.init()
        refreshPanel()
        refreshEnabled()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "dev.loam.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, NeedsYouToolbarItem.identifier, Self.newSession,
         Self.plotPanel]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case NeedsYouToolbarItem.identifier:
            return needsYou.item
        case Self.newSession:
            let (item, button) = button(id, symbol: "plus", label: "New session", help: "New session (\u{2318}T)",
                                        action: newSessionAction, axID: "new-session-button")
            newSessionButton = button
            applyEnabled()
            return item
        case Self.plotPanel:
            let (item, button) = button(id, symbol: "sidebar.right", label: "Plot panel", help: "Plot panel (\u{2318}I)",
                                        action: panelAction, axID: "panel-button")
            panelItem = item
            panelButton = button
            applyPanelCount()
            applyEnabled()
            return item
        default:
            return nil
        }
    }

    /// A bordered SF Symbol button. The button is the item's view, so the driver finds it by its ID.
    private func button(_ id: NSToolbarItem.Identifier, symbol: String, label: String, help: String,
                        action: Selector, axID: String) -> (item: NSToolbarItem, button: NSButton) {
        let item = NSToolbarItem(itemIdentifier: id)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .toolbar
        button.setAccessibilityIdentifier(axID)
        button.setAccessibilityLabel(label)
        item.view = button
        item.label = label
        item.toolTip = help
        return (item, button)
    }

    /// The count of new changes to the active plot: a badge on the item. Loam shows no banner and
    /// sends no OS notification for a plot change. The observation starts once, in `init`. The
    /// delegate may build the item again (the toolbar rebuilds it), and `applyPanelCount` sets it.
    private func refreshPanel() {
        withObservationTracking {
            _ = model.review.newCount(plot: model.workspace.activePlotID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshPanel() }
        }
        applyPanelCount()
    }

    private func applyPanelCount() {
        let count = model.review.newCount(plot: model.workspace.activePlotID)
        panelItem?.badge = count > 0 ? .count(count) : nil
        // The words that VoiceOver and the driver read, as the old title bar button had them. The
        // toolbar gives the button the item's label as its title, so the label carries them. The
        // toolbar shows icons only, so the label shows only in the overflow menu.
        let words = count > 0 ? "Plot panel \u{2318}I \u{00B7} \(count)" : "Plot panel \u{2318}I"
        panelItem?.label = words
        panelButton?.setAccessibilityLabel(words)
    }

    /// Which items take a click (`AppModel.toolbarAllows`): none while a sheet shows, and no plot panel in Home (ticket 99).
    /// The scrim of a sheet covers the title bar (ticket 126) and takes the clicks. A disabled item also refuses the
    /// accessibility press and the keys.
    private func refreshEnabled() {
        withObservationTracking {
            for action in ToolbarAction.allCases { _ = model.toolbarAllows(action) }
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshEnabled() }
        }
        applyEnabled()
    }

    private func applyEnabled() {
        newSessionButton?.isEnabled = model.toolbarAllows(.newSession)
        panelButton?.isEnabled = model.toolbarAllows(.plotPanel)
        needsYou.isEnabled = model.toolbarAllows(.needsYou)
        // The sidebar button is the system's. It validates through the responder chain, which says yes, so the state is set by hand.
        if let item = toolbar?.items.first(where: { $0.itemIdentifier == .toggleSidebar }) {
            item.autovalidates = false
            item.isEnabled = model.toolbarAllows(.toggleSidebar)
        }
    }
}
