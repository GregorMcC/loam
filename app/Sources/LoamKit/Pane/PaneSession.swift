import Foundation

/// What a pane knows about the session in it, from the pane socket (spec 8.4) and the process exit.
/// A pure value: `apply(_:)` is the state machine, so tests cover it.
///
/// - `SessionStart` sets the session ID. `/clear` and an in-session `/resume` change it.
/// - `UserPromptSubmit` and `PostToolUse` mean working. `Stop` means idle and done, unread.
/// - `PermissionRequest`, `StopFailure`, and a `Notification` of a question type mean needs you.
///   The session moving on clears it, and so does a key in the pane (`typed()`).
/// - `SessionEnd` means ended. A `SessionStart` after it (the `/clear` case) makes the pane idle again.
/// - The input of Claude Code (ticket 110). Loam cannot see it, so it counts what can change it. A key, a paste
///   or a drop sets `typedSinceSubmit` and `typedSinceReturn`, except while a dialog waits (`input()`). Your
///   Return clears `typedSinceReturn` (`pressedReturn()`). At a `UserPromptSubmit` from you (source `user`, or
///   no source from an older Claude Code), Claude Code took what you sent, so `typedSinceSubmit` becomes
///   `typedSinceReturn`: only the keys after your Return still count. A turn that Claude Code starts by itself
///   (any other source) leaves your draft in the input and changes nothing. `Stop` changes nothing either.
///   A new session (a `SessionStart` that is not a compact) starts with an empty input.
/// - The process exit means ended for good: later events change nothing.
/// - An event for another session ID changes nothing. Only `SessionStart` takes a new ID.
/// - Unknown events change nothing (docs/contract.md, "Pane socket").
public struct PaneSession: Codable, Equatable, Sendable {
    /// The session that runs in the pane now. For a seeded pane, the ID it started or resumed with
    /// until the first `SessionStart`.
    public var sessionID: String?
    /// Any state that is not needs you clears `waitsOn`, also a state set from outside.
    public var state: PaneState { didSet { if state != .needsYou { waitsOn = nil } } }
    /// True after the first `SessionStart`: a session record exists, so the session can resume.
    public var started: Bool
    /// True after the pane's process exited.
    public var exited: Bool
    /// The IDs that the pane ran before the current one, oldest first, such as the ID before `/clear`.
    public var pastSessionIDs: [String]
    /// The session's working folder, from the `cwd` of `SessionStart`. `state.json` lists it, so
    /// `loam worktree rm` knows the pane is in a worktree. Nil before the first `SessionStart`.
    public var folder: String?
    /// Done, unread (spec 8.4): a turn finished. `Stop` sets it. The app clears it when you look at
    /// the pane while Loam is frontmost. Restore brings it back (spec 8.5).
    public var doneUnread: Bool
    /// What the session waits on while the pane needs you. Nil in every other state. Restore does
    /// not bring it back, because the prompt is gone after a quit.
    public var waitsOn: NeedsYouReason?
    /// True when the input can hold your text (ticket 110): you put text into the pane, and Claude Code has not
    /// taken it since. Send to session does not type then.
    public var typedSinceSubmit = false
    /// True when you put text into the pane since your last Return that can send the input (ticket 110). A
    /// `UserPromptSubmit` that comes later takes only the text before that Return.
    public var typedSinceReturn = false
    /// The prompt that Send to session typed into the input (ticket 110). It waits there until you press Return
    /// and Claude Code takes it. Nil when Loam typed nothing.
    public var loamPrompt: String?

    public init(sessionID: String? = nil, state: PaneState = .running, started: Bool = false,
                exited: Bool = false, pastSessionIDs: [String] = [], folder: String? = nil, doneUnread: Bool = false) {
        self.sessionID = sessionID
        self.state = state
        self.started = started
        self.exited = exited
        self.pastSessionIDs = pastSessionIDs
        self.folder = folder
        self.doneUnread = doneUnread
    }

    /// Applies one line from the pane socket. Returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: PaneEvent) -> Bool {
        guard !exited else { return false }
        let before = self
        if event.event == "SessionStart" {
            if let old = sessionID, old != event.sessionID, !pastSessionIDs.contains(old) {
                pastSessionIDs.append(old)
            }
            sessionID = event.sessionID
            started = true
            if !event.cwd.isEmpty { folder = event.cwd }
            // A compact can come in the middle of a turn. It keeps the state, and the input keeps its text.
            if event.source != "compact" || state == .running || state == .ended { set(.idle) }
            // A new session starts with an empty input. `/clear` took the text, and the keys before the first
            // SessionStart went to the setup command or the trust question.
            if event.source != "compact" { emptyInput() }
            return self != before
        }
        guard sessionID == nil || event.sessionID == sessionID else { return false }
        switch event.event {
        case "UserPromptSubmit":
            set(.working)
            if event.source == nil || event.source == "user" {
                typedSinceSubmit = typedSinceReturn
                if !typedSinceReturn { loamPrompt = nil }
            }
        case "PostToolUse": set(.working)
        case "Stop":
            set(.idle)
            doneUnread = true
        case "StopFailure": needsYou(.apiError)
        case "PermissionRequest": needsYou(.permission)
        case "Notification":
            // The core sends only the attention types. Any other type changes nothing.
            switch event.notificationType {
            case "elicitation_dialog", "elicitation_url_dialog": needsYou(.question)
            case "agent_needs_input": needsYou(.input)
            case "permission_prompt":
                // A tool prompt sends this after PermissionRequest. A pane that already needs you keeps its reason.
                if state != .needsYou { needsYou(.permission) }
            default: break
            }
        case "SessionEnd": set(.ended)
        default: break
        }
        return self != before
    }

    /// You typed in the pane. Needs you clears (spec 8.4), because a denied permission prompt sends
    /// no hook at all. A permission prompt or a question comes mid-turn, so the pane is working
    /// again. After an API error the turn is over, so the pane is idle. Returns true when needs you cleared.
    @discardableResult
    public mutating func typed() -> Bool {
        guard state == .needsYou else { return false }
        set(waitsOn == .apiError ? .idle : .working)
        return true
    }

    /// The pane's process exited. The pane stays and shows "Session ended".
    public mutating func processExited() {
        exited = true
        set(.ended)
    }

    /// You put something into the input of the pane: a key, a paste, or a drop. Send to session does not type
    /// until Claude Code takes the input (ticket 110). While a permission dialog or a question waits, the keys
    /// go to the dialog, so they do not count. Needs you stays, because an arrow key or Tab only picks an option
    /// of a prompt (`typed()` clears it).
    public mutating func input() {
        guard !waitsOnDialog else { return }
        typedSinceSubmit = true
        typedSinceReturn = true
    }

    /// You pressed a Return that can send the input (ticket 110). A Return in a dialog answers the dialog.
    public mutating func pressedReturn() {
        guard !waitsOnDialog else { return }
        typedSinceReturn = false
    }

    /// A permission dialog or a question takes the keys. After an API error and for `agent_needs_input`, the keys
    /// go to the input.
    private var waitsOnDialog: Bool { waitsOn == .permission || waitsOn == .question }

    /// The input of Claude Code is empty: a new session started.
    private mutating func emptyInput() {
        typedSinceSubmit = false
        typedSinceReturn = false
        loamPrompt = nil
    }

    /// A state that is not needs you. The `state` observer clears what the session waited on.
    private mutating func set(_ next: PaneState) { state = next }

    private mutating func needsYou(_ reason: NeedsYouReason) {
        state = .needsYou
        waitsOn = reason
    }

    /// True when the pane ran this session ID, now or before.
    public func ran(_ id: String) -> Bool { sessionID == id || pastSessionIDs.contains(id) }
}

/// What a session that needs you waits on (spec 8.4).
public enum NeedsYouReason: String, Codable, Equatable, Sendable {
    /// `PermissionRequest` or a `Notification` of type `permission_prompt`: a dialog asks for permission.
    case permission
    /// A `Notification` of type `elicitation_dialog` or `elicitation_url_dialog`.
    case question
    /// A `Notification` of type `agent_needs_input`.
    case input
    /// `StopFailure`: the turn stopped on an API error.
    case apiError
}
