import Foundation

/// A pane that runs a session. The app wires the lookup from a session ID to its pane.
public struct PaneRef: Equatable, Sendable {
    public var id: PaneID
    /// The pane name, such as "claude · app layout".
    public var name: String
    public init(id: PaneID, name: String) { self.id = id; self.name = name }
}

/// The label of the actor of a change (spec 8.6).
public struct ActorLabel: Equatable, Sendable {
    public var text: String
    /// Shown on hover: the full session ID of a session that has no pane name to show.
    public var hover: String?
    /// Set when a click goes to a pane.
    public var pane: PaneRef?

    public static func make(_ actor: Actor, pane: PaneRef?) -> ActorLabel {
        switch actor.kind {
        case .app:
            return ActorLabel(text: "You")
        case .cli:
            return ActorLabel(text: "You \u{00B7} CLI")
        case .session:
            let id = actor.sessionID ?? ""
            let short = String(id.prefix(6))
            let hover = id.isEmpty ? nil : id
            if actor.loamStarted == true {
                if let pane { return ActorLabel(text: pane.name, pane: pane) }
                // A session that Loam started has no pane open now. The core gives no name, so the label shows the ID start.
                return ActorLabel(text: short.isEmpty ? "claude" : "claude \u{00B7} \(short)", hover: hover)
            }
            return ActorLabel(
                text: short.isEmpty ? "claude \u{00B7} outside Loam" : "claude \u{00B7} outside Loam \(short)", hover: hover)
        }
    }
}
