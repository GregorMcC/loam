import Foundation

/// The question before ⌘W, `close_tab`, archive, or quit (spec 8.2 and 8.5). The app asks only when
/// a session that the close ends is mid-turn or needs you, because a turn in progress loses its
/// partial reply (ADR 0005), and a session that needs you waits for your answer.
public struct ClosePrompt: Equatable, Sendable {
    public enum Scope: Sendable { case pane, tab, quit, archive }

    public let title: String
    public let message: String
    /// The button that goes ahead. The other button is "Cancel".
    public let confirm: String

    /// True when closing the pane must ask first: a seeded pane whose session is mid-turn or needs you.
    public static func asks(for pane: PaneID, in workspace: Workspace) -> Bool {
        guard workspace.spec(of: pane)?.kind == .session else { return false }
        return workspace.state(of: pane) == .working || workspace.state(of: pane) == .needsYou
    }

    /// The question for a close of `panes`, or nil when no pane asks and the close goes ahead at once.
    public static func make(_ scope: Scope, closing panes: [PaneID], in workspace: Workspace) -> ClosePrompt? {
        let asking = panes.filter { asks(for: $0, in: workspace) }
        guard !asking.isEmpty else { return nil }
        let needs = asking.filter { workspace.state(of: $0) == .needsYou }.count
        let working = asking.count - needs
        let one = asking.count == 1
        let stops = one ? "the session stops and loses its partial reply." : "the sessions stop and lose their partial replies."
        switch scope {
        case .pane:
            let what = needs > 0 ? "needs you" : "is mid-turn"
            return ClosePrompt(
                title: "Close this pane?",
                message: "The session in this pane \(what). If you close the pane, the session stops and loses its partial reply.",
                confirm: "Close")
        case .tab:
            return ClosePrompt(
                title: "Close this tab?",
                message: "\(count(working, needs, in: " in this tab")) If you close the tab, \(stops)",
                confirm: "Close")
        case .archive:
            let resumes = one ? "Loam resumes the session" : "Loam resumes the sessions"
            return ClosePrompt(
                title: "Archive this plot?",
                message: "\(count(working, needs, in: " in this plot")) If you archive the plot, \(stops) \(resumes) when you unarchive the plot and show it.",
                confirm: "Archive")
        case .quit:
            let resumes = one ? "Loam resumes the session" : "Loam resumes the sessions"
            return ClosePrompt(
                title: "Quit Loam?",
                message: "\(count(working, needs, in: "")) If you quit, \(stops) \(resumes) at the next launch.",
                confirm: "Quit")
        }
    }

    /// "1 session is mid-turn.", "2 sessions need you.", or "1 session is mid-turn and 1 needs you."
    private static func count(_ working: Int, _ needs: Int, in place: String) -> String {
        func sessions(_ n: Int) -> String { n == 1 ? "1 session\(place)" : "\(n) sessions\(place)" }
        func midTurn(_ n: Int) -> String { n == 1 ? "is mid-turn" : "are mid-turn" }
        func needYou(_ n: Int) -> String { n == 1 ? "needs you" : "need you" }
        if needs == 0 { return "\(sessions(working)) \(midTurn(working))." }
        if working == 0 { return "\(sessions(needs)) \(needYou(needs))." }
        return "\(sessions(working)) \(midTurn(working)) and \(needs) \(needYou(needs))."
    }
}
