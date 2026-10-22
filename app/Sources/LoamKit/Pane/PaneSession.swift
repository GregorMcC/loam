import Foundation

/// What a pane knows about the session in it, from the pane socket (spec 8.4) and the process exit.
/// A pure value: `apply(_:)` is the state machine, so tests cover it.
///
/// - `SessionStart` sets the session ID. `/clear` and an in-session `/resume` change it.
/// - `UserPromptSubmit` and `PostToolUse` mean working. `Stop` means idle and done, unread.
/// - `PermissionRequest`, `StopFailure`, and a `Notification` of a question type mean needs you.
///   The session moving on clears it, and so does a key in the pane (`typed()`).
/// - `SessionEnd` means ended. A `SessionStart` after it (the `/clear` case) makes the pane idle again.
/// - The composer rule (ticket 110). Loam cannot see the composer of Claude Code, so it counts what can change it,
///   and Send to session types only when `typedSinceSubmit` is false. Each event and what it does:
///   - A key that counts as input (`InputKey.input`) sets `typedSinceSubmit` and `typedSinceReturn`. While
///     `dialogOpen`, it does nothing, because the dialog takes the key.
///   - A paste, a drop, or text from dictation or a picker (`PaneInput.text`) sets both, also while `dialogOpen`.
///     The dialog may have closed before its next hook line, and too careful is fine.
///   - A submit Return (`InputKey.submit`) clears `typedSinceReturn` and sets `pendingSubmit` to now. While
///     `dialogOpen`, it does nothing, because it answers the dialog.
///   - `UserPromptSubmit` with source `user`, or with no source (Claude Code does not send one today), takes the
///     composer only when `pendingSubmit` is at most `submitWindow` old: `typedSinceSubmit` becomes
///     `typedSinceReturn`, `loamPrompt` clears when `typedSinceReturn` is false, and `pendingSubmit` ends. With
///     no pending Return it changes nothing, because a background task, a message from a peer, or an
///     auto-continuation starts a turn with the same line while your text stays in the composer.
///   - `UserPromptSubmit` with any other source changes nothing, and `pendingSubmit` stays.
///   - Send to session types `loamPrompt` with no Return (`prompted(_:)`). A Return before it did not send it, so
///     `pendingSubmit` ends.
///   - `PermissionRequest`, and a `Notification` of type `elicitation_dialog`, `elicitation_url_dialog` or
///     `permission_prompt`, set `dialogOpen`. `agent_needs_input` and `StopFailure` do not, because their keys
///     go to the composer.
///   - Every other event of the session closes the dialog: `PostToolUse`, `UserPromptSubmit`, `Stop`,
///     `StopFailure`, `SessionStart`, `SessionEnd`, and an event that Loam does not know, such as `PreToolUse`.
///     So does the process exit. A key does not.
///   - `Stop` changes nothing else, because Claude Code keeps a draft that you typed during the turn.
///   - `SessionStart` with source `startup`, `resume` or `clear` starts with an empty composer, so all of the
///     rule resets. Any other source, such as `compact` or `fork`, keeps it.
/// - The process exit means ended for good: later events change nothing.
/// - An event for another session ID changes nothing. Only `SessionStart` takes a new ID.
/// - Unknown events change nothing else (docs/contract.md, "Pane socket"). They close a dialog (the composer rule).
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
    /// True when the composer can hold your text (ticket 110): you put text into the pane, and Claude Code has not
    /// taken it since. Send to session does not type then.
    public var typedSinceSubmit = false
    /// True when you put text into the pane since your last submit Return (ticket 110). The `UserPromptSubmit` of
    /// that Return takes only the text before it.
    public var typedSinceReturn = false
    /// The time of your last submit Return, until a `UserPromptSubmit` takes it (ticket 110).
    public var pendingSubmit: Date?
    /// True while a permission dialog or a question takes the keys (ticket 110). It is the belief of the composer
    /// rule, apart from needs you: a key ends needs you, but only the next hook event closes the dialog.
    public var dialogOpen = false
    /// The prompt that Send to session typed into the composer (ticket 110). It waits there until you press
    /// Return and Claude Code takes it. Nil when Loam typed nothing.
    public var loamPrompt: String?
    /// How long after your Return its `UserPromptSubmit` can come. The hook line comes about 200 ms after it.
    public static let submitWindow: TimeInterval = 3
    /// The sources of a `SessionStart` that begin with an empty composer.
    static let emptyComposerSources: Set<String> = ["startup", "resume", "clear"]

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

    /// Applies one line from the pane socket that came at `now`. Returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: PaneEvent, now: Date = Date()) -> Bool {
        guard !exited else { return false }
        let before = self
        if event.event == "SessionStart" {
            if let old = sessionID, old != event.sessionID, !pastSessionIDs.contains(old) {
                pastSessionIDs.append(old)
            }
            sessionID = event.sessionID
            started = true
            if !event.cwd.isEmpty { folder = event.cwd }
            // A compact can come in the middle of a turn. It keeps the state.
            if event.source != "compact" || state == .running || state == .ended { set(.idle) }
            dialogOpen = false
            // `/clear` took the text, and the keys before the first SessionStart went to the setup command or the
            // trust question. A compact, a fork, or a source that Loam does not know keeps the composer.
            if let source = event.source, Self.emptyComposerSources.contains(source) { emptyComposer() }
            return self != before
        }
        guard sessionID == nil || event.sessionID == sessionID else { return false }
        dialogOpen = Self.opensDialog(event)
        switch event.event {
        case "UserPromptSubmit":
            set(.working)
            if event.source == nil || event.source == "user" { tookSubmit(now: now) }
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
        dialogOpen = false
        set(.ended)
    }

    // MARK: The composer rule (ticket 110)

    /// You put something into the composer of the pane (see the composer rule above). Needs you stays, because an
    /// arrow key or Tab only picks an option of a prompt (`typed()` clears it).
    public mutating func input(_ kind: PaneInput) {
        if kind == .key, dialogOpen { return }
        typedSinceSubmit = true
        typedSinceReturn = true
    }

    /// You pressed a submit Return at `now` (see the composer rule above).
    public mutating func pressedReturn(now: Date = Date()) {
        guard !dialogOpen else { return }
        typedSinceReturn = false
        pendingSubmit = now
    }

    /// Send to session typed `prompt` into the composer with no Return (see the composer rule above).
    public mutating func prompted(_ prompt: String) {
        loamPrompt = prompt
        pendingSubmit = nil
    }

    /// A `UserPromptSubmit` from you, or one that looks the same. It takes the composer only after your Return.
    private mutating func tookSubmit(now: Date) {
        guard let pending = pendingSubmit, now.timeIntervalSince(pending) <= Self.submitWindow else { return }
        typedSinceSubmit = typedSinceReturn
        if !typedSinceReturn { loamPrompt = nil }
        pendingSubmit = nil
    }

    /// The composer is empty: a new session started.
    private mutating func emptyComposer() {
        typedSinceSubmit = false
        typedSinceReturn = false
        pendingSubmit = nil
        loamPrompt = nil
    }

    /// True for the events that open a dialog that takes the keys.
    private static func opensDialog(_ event: PaneEvent) -> Bool {
        switch event.event {
        case "PermissionRequest": true
        case "Notification":
            ["elicitation_dialog", "elicitation_url_dialog", "permission_prompt"].contains(event.notificationType ?? "")
        default: false
        }
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
