import Foundation

/// What Send to session does for a worktree now (ticket 110): type the fix prompt into the session of the
/// worktree, copy the prompt, or start a session that gets it. A pure value from the workspace, so tests cover
/// the rule. Loam never presses Return, and it types only into an input that it knows is empty.
public struct SendPlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Loam focuses the pane and types the prompt into its input. You press Return.
        case type(PaneID)
        /// Loam cannot type into the session now. The button copies the prompt.
        case copy(CopyReason)
        /// No session runs in the worktree. Loam starts one and types the prompt after its `SessionStart`.
        case start
    }

    /// Why Loam cannot type into the session.
    public enum CopyReason: Equatable, Sendable {
        /// The session is in a turn, or it waits on you.
        case busy
        /// The session has not sent its `SessionStart`, such as while the setup command runs.
        case starting
        /// You put text into the session since Claude Code last took its input.
        case typed
        /// Loam typed another prompt into the session, and you have not sent it.
        case prompted
    }

    public let prompt: FixPrompt
    public let step: Step
    /// The name of the session pane, as the tab bar shows it, such as "✳ Native panel spacing". Nil when no
    /// session runs in the worktree.
    public let paneName: String?

    /// The plan for the worktree, with its prompt. `lastFocus` orders the panes by when they last had the focus,
    /// the highest last. `titles` are the titles that the terminals set.
    public init(prompt: FixPrompt, worktree: Worktree, in workspace: Workspace, lastFocus: [PaneID: Int],
                titles: [PaneID: String]) {
        self.prompt = prompt
        guard let pane = Self.target(of: worktree, in: workspace, lastFocus: lastFocus),
              let session = workspace.session(of: pane) else {
            step = .start
            paneName = nil
            return
        }
        step = Self.step(for: pane, session: session, prompt: prompt.text)
        paneName = workspace.title(of: pane, terminalTitles: titles)
    }

    /// The session pane that gets the prompt: a seeded session of the worktree, in its plot, whose session has
    /// not ended. Of two or more, the one that you focused last, else the first in tab order. A saved pane that
    /// has not resumed counts too: it is `running` until its `SessionStart`, so Loam offers Copy prompt and does
    /// not start a second session.
    public static func target(of worktree: Worktree, in workspace: Workspace, lastFocus: [PaneID: Int]) -> PaneID? {
        let panes = workspace.paneIDs(of: .plot(worktree.plotID)).filter { pane in
            guard let spec = workspace.spec(of: pane), spec.kind == .session, spec.worktree?.id == worktree.id,
                  let session = workspace.session(of: pane) else { return false }
            return !session.exited && session.state != .ended
        }
        return panes.max { (lastFocus[$0] ?? 0) < (lastFocus[$1] ?? 0) }
    }

    /// The rule for when Loam may type into a session. The session must be idle, and its input must be empty
    /// of your text: you put no text into it since Claude Code last took the input. The prompt that Loam typed
    /// is in the input already, so the same prompt types nothing new, and another prompt does not go on top of it.
    public static func step(for pane: PaneID, session: PaneSession, prompt: String) -> Step {
        switch session.state {
        case .idle: break
        case .running: return .copy(.starting)
        case .working, .needsYou: return .copy(.busy)
        // `target` never gives an ended session. A session that ends after the plan was made gets a new one.
        case .ended: return .start
        }
        if session.typedSinceSubmit { return .copy(.typed) }
        if let typed = session.loamPrompt, typed != prompt { return .copy(.prompted) }
        return .type(pane)
    }

    // MARK: Words

    /// The name of the pane that Loam types into now, for the primary button of the PR popover. Nil when Loam
    /// copies the prompt or starts a session.
    public var typeTarget: String? {
        guard case .type = step else { return nil }
        return paneName
    }

    /// The primary button of the PR popover.
    public var buttonTitle: String {
        switch step {
        case .type: prompt.kind.action.title
        case .copy: "Copy prompt"
        case .start: "Start session with prompt"
        }
    }

    /// The line under the buttons of the PR popover. It says what the button does, or why Loam cannot type.
    public var footnote: String {
        switch step {
        case .type: "Loam types the prompt into the session. You press Return."
        case .copy(.busy): "The session is busy. Copy the prompt and send it when the turn ends."
        case .copy(.starting): "The session has not started. Copy the prompt and send it when it starts."
        case .copy(.typed): "You have typed in this session. Loam does not type over your text."
        case .copy(.prompted): "This session has a prompt from Loam that you have not sent. Loam does not type over it."
        case .start: "No session runs in this worktree. Loam starts one and types the \(prompt.kind.rawValue) prompt. You press Return."
        }
    }

    /// The toast after Loam typed the prompt into the pane. Nil when Loam does not type now.
    public var toast: String? {
        typeTarget.map { Self.toast(prompt.kind, into: $0) }
    }

    /// The toast after Loam typed a prompt into the pane with this name, such as "Loam typed the failures into
    /// ✳ Native panel spacing. Press Return to send."
    public static func toast(_ kind: FixPrompt.Kind, into paneName: String) -> String {
        "Loam typed the \(kind.rawValue) into \(paneName). Press Return to send."
    }

    /// The toast after Loam typed a prompt into the session that Start session with prompt opened. The session may
    /// not have set its title yet at its `SessionStart`, so the toast does not name it by the title.
    public static func toastForNewSession(_ kind: FixPrompt.Kind) -> String {
        toast(kind, into: "the new session")
    }

    /// The notice when the new session sent no `SessionStart` in the 30 seconds of `AppModel.sessionStartWait`. It
    /// names the worktree, because you may work in another pane by then. Nil when the worktree is gone.
    public static func notStartedToast(worktree: String?) -> String {
        let session = worktree.map { "The session in \($0)" } ?? "The session"
        return "\(session) did not start in 30 seconds. Loam did not type the prompt."
    }
}
