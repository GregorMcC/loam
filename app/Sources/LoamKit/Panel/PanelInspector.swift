import Foundation

extension PlotLink {
    /// The kind at the right of a link row in the plot panel (ticket 87): Local, Vault, GitHub, Web, Notion, or Linear.
    public var kindLabel: String {
        switch kind {
        case .path: "Local"
        case .vault: "Vault"
        case .github: "GitHub"
        case .url: "Web"
        case .notion: "Notion"
        case .linear: "Linear"
        }
    }
}

/// The property rows at the top of the plot panel.
public enum PanelProperties {
    /// "3 panes · 1 Done, unread". With no pane: "No panes".
    public static func paneSummary(panes: Int, needsYou: Int, doneUnread: Int) -> String {
        guard panes > 0 else { return "No panes" }
        var text = panes == 1 ? "1 pane" : "\(panes) panes"
        var states: [String] = []
        if needsYou > 0 { states.append(needsYou == 1 ? "1 Needs you" : "\(needsYou) Need you") }
        if doneUnread > 0 { states.append("\(doneUnread) Done, unread") }
        if !states.isEmpty { text += " \u{00B7} " + states.joined(separator: ", ") }
        return text
    }
}

/// The avatar of the actor of a change.
public enum ActorGlyph: Equatable, Sendable { case claude, person, terminal }

extension ChangeRules {
    /// "Claude" for a session, else "You".
    public static func actorName(_ actor: Actor) -> String {
        actor.kind == .session ? "Claude" : "You"
    }

    public static func actorGlyph(_ actor: Actor) -> ActorGlyph {
        switch actor.kind {
        case .session: .claude
        case .app: .person
        case .cli: .terminal
        }
    }

    /// What follows the actor in a timeline row: "set Where it stands", "added link", "undid change 4".
    public static func sentence(_ change: Change) -> String {
        let line = summary(change)
        let parts = line.components(separatedBy: ", ")
        if parts.allSatisfy({ $0.hasPrefix("Edited ") }) {
            return "set " + parts.map { String($0.dropFirst("Edited ".count)) }.joined(separator: ", ")
        }
        guard let first = line.first else { return line }
        return first.lowercased() + line.dropFirst()
    }

    /// The source in the caption of a timeline row. A session in a pane takes the pane name.
    public static func source(_ actor: Actor, paneName: String?) -> String {
        switch actor.kind {
        case .app: "app"
        case .cli: "CLI"
        case .session:
            if actor.loamStarted == true { paneName ?? "seeded session" } else { "another Claude session" }
        }
    }
}
