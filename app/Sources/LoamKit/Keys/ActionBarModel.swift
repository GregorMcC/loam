import Foundation
import Observation

/// The bottom action bar (ticket 89): the focused plot and pane on the left, then the last change as a
/// short toast or the PR of the pane's worktree as a chip (ticket 109), and the actions menu.
@MainActor @Observable
public final class ActionBarModel {
    /// The active plot. A switch to another plot clears the toast, which named a change of the last one.
    public var plotID: String? {
        didSet { if plotID != oldValue { toast = nil } }
    }
    /// The name of the active plot, or "Home".
    public var plotName = ""
    /// Home is active (ticket 99). The bar shows the Home symbol in place of the plot symbol.
    public var isHome = false
    /// The label of the focused tab: the title of its focused pane.
    public var paneLabel = ""
    /// The PR of the worktree that the focused pane runs in. Nil for a pane in the main checkout or in Home,
    /// and for a worktree with no PR.
    public var chip: StageMark?
    /// The last change of the active plot, such as "Claude set Where it stands", or a line from the app
    /// (`show`). Nil when none shows.
    public private(set) var toast: String?
    /// What the toast says about itself. The bar shows its glyph.
    public private(set) var toastKind = ToastKind.done
    /// Counts the toasts, so a fade-out timer clears only its own toast.
    public private(set) var toastID = 0
    public let menu = ActionMenuModel()

    /// A change or an action that went through shows a check in `moss`. A notice says that something did not
    /// happen, such as a session that did not start, and shows `exclamationmark.circle` in `ink-muted`.
    public enum ToastKind: Equatable, Sendable {
        case done
        case notice
    }

    /// What the bar shows after the pane label. The toast and the chip share the place, and the toast wins
    /// while it shows.
    public enum Trailing: Equatable, Sendable {
        case toast(String)
        case chip(StageMark)
        case nothing
    }

    public var trailing: Trailing {
        if let toast { return .toast(toast) }
        if let chip { return .chip(chip) }
        return .nothing
    }
    /// How long a toast shows before it fades.
    public static let toastSeconds: Double = 6

    @ObservationIgnored private var lastChangeID: Int?
    /// The changes that the app made and told about in its own toast (`ignoreChange`).
    @ObservationIgnored private var ownChanges: Set<Int> = []

    public init() {}

    /// The change log was read. A change that is new since the last read, in the active plot,
    /// shows as the toast. The first read only notes where the log stands.
    public func changesArrived(_ changes: [Change], activePlot: String?) {
        let newest = changes.map(\.id).max()
        defer { if let newest { lastChangeID = max(lastChangeID ?? newest, newest) } else if lastChangeID == nil { lastChangeID = 0 } }
        guard let seen = lastChangeID else { return }
        guard let change = changes.filter({ $0.id > seen && $0.plotID == activePlot && !ownChanges.contains($0.id) })
            .max(by: { $0.id < $1.id }) else { return }
        toast = ChangeRules.actorName(change.actor) + " " + ChangeRules.sentence(change)
        toastKind = .done
        toastID += 1
    }

    /// A change that the app made itself, such as the Where it stands of a land (ticket 112), has a toast of its own.
    /// The next read of the log does not replace that toast with "You set Where it stands".
    public func ignoreChange(_ id: Int) {
        ownChanges.insert(id)
    }

    /// Shows a line from the app as the toast, such as "Loam typed the failures into ✳ Native panel spacing.
    /// Press Return to send." (ticket 110). It fades as the toast of a change does.
    public func show(_ line: String, kind: ToastKind = .done) {
        toast = line
        toastKind = kind
        toastID += 1
    }

    /// The fade-out timer of toast `id` ran out.
    public func clearToast(id: Int) {
        guard id == toastID else { return }
        toast = nil
    }
}
