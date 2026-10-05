import AppKit
import LoamKit
import Observation

/// The "N elsewhere need you" button, a toolbar item (spec 8.1, ticket 69). It shows only while the
/// sidebar is hidden and a pane in another plot needs you. A click goes to the next of those panes.
/// The item hides with `isHidden`, so the toolbar keeps its place at the trailing edge.
@MainActor
final class NeedsYouToolbarItem {
    static let identifier = NSToolbarItem.Identifier("dev.loam.needs-you")

    let item = NSToolbarItem(itemIdentifier: identifier)
    private let model: AppModel
    private let button = NSButton(title: "", target: nil, action: nil)

    init(model: AppModel) {
        self.model = model
        button.target = self
        button.action = #selector(goToNext(_:))
        button.bezelStyle = .toolbar
        button.setAccessibilityIdentifier("needs-you-button")
        item.view = button
        item.label = "Elsewhere needs you"
        item.isHidden = true
        refresh()
    }

    @objc private func goToNext(_ sender: Any?) {
        model.goToNextPaneThatNeedsYou(elsewhere: true)
    }

    /// Sets the title and shows or hides the item, and watches the model for the next change.
    private func refresh() {
        let (collapsed, count) = withObservationTracking {
            (model.sidebarCollapsed, model.elsewhereNeedYouCount)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let title = count == 1 ? "1 elsewhere needs you" : "\(count) elsewhere need you"
        button.attributedTitle = NSAttributedString(string: "\u{25CF} " + title, attributes: [
            .foregroundColor: LoamTheme.needsYou,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        item.label = title
        item.isHidden = !(collapsed && count > 0)
    }
}
