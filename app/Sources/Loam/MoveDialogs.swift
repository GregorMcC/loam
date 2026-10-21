import AppKit
import LoamKit

/// Move to Plot (ticket 100): the question before a move, the name of a new plot, and the menu of a
/// Home tab in the tab bar. The decisions live in `AppModel`. `window` nil shows the sheets on the key window.
@MainActor
enum MoveDialogs {
    /// Moves the tab. It asks first when a session in the tab is mid-turn or needs you (`ClosePrompt`).
    static func askMove(_ tab: UUID, to plot: String, model: AppModel, on window: NSWindow? = nil) {
        PlotDialogs.confirm(model.movePrompt(tab: tab), on: window) { model.moveToPlot(tab: tab, plot: plot) }
    }

    /// The name, then the question, so the question shows the sessions as they are at the move,
    /// and a Cancel makes no plot. The question waits for the next turn of the run loop, so the
    /// name sheet is gone first.
    static func askMoveToNewPlot(_ tab: UUID, model: AppModel, on window: NSWindow? = nil) {
        PlotDialogs.askName(on: window) { name in
            // A blank name makes no plot, so there is nothing to ask.
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.main.async {
                PlotDialogs.confirm(model.movePrompt(tab: tab), on: window) {
                    Task { @MainActor in await model.moveToNewPlot(tab: tab, named: name) }
                }
            }
        }
    }

    /// The context menu of the tab at `index` of the active space. Only a Home tab has one.
    static func tabMenu(at index: Int, model: AppModel, on window: NSWindow?) -> NSMenu? {
        guard model.workspace.activeSpace == .home else { return nil }
        let tabs = model.workspace.tabs(of: .home)
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index].id
        let plots = NSMenu()
        for plot in model.moveTargets {
            plots.addItem(MenuAction.item(plot.name) { askMove(tab, to: plot.id, model: model, on: window) })
        }
        if !plots.items.isEmpty { plots.addItem(.separator()) }
        plots.addItem(MenuAction.item("New Plot\u{2026}") { askMoveToNewPlot(tab, model: model, on: window) })
        let move = NSMenuItem(title: "Move to Plot", action: nil, keyEquivalent: "")
        move.submenu = plots
        let menu = NSMenu()
        menu.addItem(move)
        return menu
    }
}

/// A menu item that runs a closure. The item keeps the action as its represented object, because
/// its target is a weak reference.
private final class MenuAction: NSObject {
    private let body: @MainActor () -> Void

    private init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    @MainActor
    static func item(_ title: String, run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }

    @MainActor @objc private func run() { body() }
}
