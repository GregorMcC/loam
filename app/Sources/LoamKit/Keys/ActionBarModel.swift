import Foundation
import Observation

/// The bottom action bar (ticket 89): the focused plot and pane on the left, the last change as a
/// short toast, and the actions menu.
@MainActor @Observable
public final class ActionBarModel {
    /// The active plot. A switch to another plot clears the toast, which named a change of the last one.
    public var plotID: String? {
        didSet { if plotID != oldValue { toast = nil } }
    }
    /// The name of the active plot.
    public var plotName = ""
    /// The label of the focused tab: the title of its focused pane.
    public var paneLabel = ""
    /// The last change of the active plot, such as "Claude set Where it stands". Nil when none shows.
    public private(set) var toast: String?
    /// Counts the toasts, so a fade-out timer clears only its own toast.
    public private(set) var toastID = 0
    public let menu = ActionMenuModel()
    /// How long a toast shows before it fades.
    public static let toastSeconds: Double = 6

    @ObservationIgnored private var lastChangeID: Int?

    public init() {}

    /// The change log was read. A change that is new since the last read, in the active plot,
    /// shows as the toast. The first read only notes where the log stands.
    public func changesArrived(_ changes: [Change], activePlot: String?) {
        let newest = changes.map(\.id).max()
        defer { if let newest { lastChangeID = max(lastChangeID ?? newest, newest) } else if lastChangeID == nil { lastChangeID = 0 } }
        guard let seen = lastChangeID else { return }
        guard let change = changes.filter({ $0.id > seen && $0.plotID == activePlot }).max(by: { $0.id < $1.id }) else { return }
        toast = ChangeRules.actorName(change.actor) + " " + ChangeRules.sentence(change)
        toastID += 1
    }

    /// The fade-out timer of toast `id` ran out.
    public func clearToast(id: Int) {
        guard id == toastID else { return }
        toast = nil
    }
}
