import Foundation

/// What a pane knows about the session in it, from the pane socket (spec 8.4) and the process exit.
/// A pure value: `apply(_:)` is the state machine, so tests cover it.
///
/// - `SessionStart` sets the session ID. `/clear` and an in-session `/resume` change it.
/// - `UserPromptSubmit`, `PostToolUse` and `PostToolUseFailure` mean working. `Stop` means idle and done, unread.
/// - `PermissionRequest`, `StopFailure`, and a `Notification` of a question type mean needs you.
///   The session moving on clears it, and so does a key in the pane (`typed()`).
/// - `SessionEnd` means ended. A `SessionStart` after it (the `/clear` case) makes the pane idle again.
/// - The composer rule (ticket 110). Loam cannot see the composer of Claude Code, so it counts what can change it,
///   and Send to session types only when `typedSinceSubmit` is false. `PaneInput` sorts the keys. Each input and
///   event, and what it does:
///   - A key (`.key`, or `.pick` and `.escape` outside a dialog) sets `typedSinceSubmit` and `typedSinceReturn`.
///   - ⌃S (`.stash`) is a key that also sets `stashPending`: Claude Code keeps the draft aside and puts it back
///     into the composer at the next submit, or after `/clear` or a `/resume` inside the session.
///   - A paste, a drop, or text from dictation or a picker (`.text`) sets both, also while `dialogOpen`. The
///     dialog may have closed before Loam knows, and too careful is fine.
///   - A submit Return (`.submit`) clears `typedSinceReturn` and sets `pendingSubmit` to now. While
///     `dialogAnswered`, it does nothing, because it can still be a key of the dialog, such as the Return on the
///     submit screen of a question with several parts.
///   - While `dialogOpen`, the dialog takes the keys. The first answer key closes it for Loam and sets
///     `dialogAnswered`: a Return or a digit picks an option and is not input, and an Escape denies and counts as
///     input, because it can stop a turn and put a queued prompt back into the composer. Other keys do nothing.
///   - `UserPromptSubmit` with source `user`, or with no source (Claude Code does not send one today), takes the
///     composer only when `pendingSubmit` is 0 to `submitWindow` seconds old: `typedSinceSubmit` becomes
///     `typedSinceReturn`, `loamPrompt` clears when `typedSinceReturn` is false, and `pendingSubmit` ends.
///     While `stashPending`, the stash comes back, so `typedSinceSubmit` stays set, `loamPrompt` stays, and
///     `stashPending` ends. With no pending Return it changes nothing, because a background task, a message
///     from a peer, or an auto-continuation starts a turn with the same line while your text stays in the
///     composer.
///   - `UserPromptSubmit` with any other source changes nothing, and `pendingSubmit` stays.
///   - Send to session types `loamPrompt` with no Return (`prompted(_:)`). A Return before it did not send it, so
///     `pendingSubmit` ends.
///   - `PermissionRequest`, and a `Notification` of type `elicitation_dialog` or `elicitation_url_dialog`, open a
///     dialog: `dialogOpen` is set and `dialogAnswered` clears. `agent_needs_input` and `StopFailure` do not,
///     because their keys go to the composer.
///   - A `Notification` of type `permission_prompt` opens a dialog only when `dialogAnswered` is false. Claude Code
///     sends it 6 seconds after a dialog opens and cancels it when the dialog closes, so it can still come just
///     after your answer key.
///   - Every other event of the session closes the dialog and clears `dialogAnswered`: `PostToolUse`,
///     `PostToolUseFailure`, a `Notification` of type `elicitation_response` or `elicitation_complete`,
///     `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionStart`, `SessionEnd`, and an event that Loam does not
///     know. So does the process exit.
///   - `Stop` changes nothing else, because Claude Code keeps a draft that you typed during the turn.
///   - `SessionStart` with source `startup`, `resume` or `clear` starts with an empty composer, so all of the
///     rule resets. A new process cannot put a stash back, but for `clear`, and for a `resume` inside a session
///     that started before, the stash comes back while `stashPending`: the flags stay set, `loamPrompt` stays,
///     and `stashPending` ends. Any other source, such as `compact` or `fork`, keeps all of the rule.
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
    /// rule, apart from needs you: any key ends needs you, but only an answer key or a hook event closes the dialog.
    public var dialogOpen = false
    /// True after an answer key closed a dialog, until the next hook event other than `permission_prompt`
    /// (ticket 110).
    public var dialogAnswered = false
    /// True after ⌃S stashed a draft, until the next submit or new session puts it back (ticket 110).
    public var stashPending = false
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
    public mutating func apply(_ event: PaneEvent, now: Date) -> Bool {
        guard !exited else { return false }
        let before = self
        if event.event == "SessionStart" {
            if let old = sessionID, old != event.sessionID, !pastSessionIDs.contains(old) {
                pastSessionIDs.append(old)
            }
            sessionID = event.sessionID
            let inSession = started
            started = true
            if !event.cwd.isEmpty { folder = event.cwd }
            // A compact can come in the middle of a turn. It keeps the state.
            if event.source != "compact" || state == .running || state == .ended { set(.idle) }
            dialogOpen = false
            dialogAnswered = false
            // `/clear` took the text, and the keys before the first SessionStart went to the setup command or the
            // trust question. A compact, a fork, or a source that Loam does not know keeps the composer. A new
            // process cannot put a stash back, but `/clear` and a `/resume` inside the session can.
            if let source = event.source, Self.emptyComposerSources.contains(source) {
                emptyComposer(stashComesBack: source == "clear" || (source == "resume" && inSession))
            }
            return self != before
        }
        guard sessionID == nil || event.sessionID == sessionID else { return false }
        followDialog(event)
        switch event.event {
        case "UserPromptSubmit":
            set(.working)
            if event.source == nil || event.source == "user" { tookSubmit(now: now) }
        case "PostToolUse", "PostToolUseFailure": set(.working)
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
        dialogAnswered = false
        set(.ended)
    }

    // MARK: The composer rule (ticket 110)

    /// You put something into the pane at `now` (see the composer rule above). Needs you stays, because an arrow
    /// key or Tab only moves in a prompt (`typed()` clears it).
    public mutating func input(_ input: PaneInput, now: Date) {
        if dialogOpen {
            switch input {
            case .submit, .pick: answerDialog()
            case .escape:
                answerDialog()
                putIntoComposer()
            case .text: putIntoComposer()
            case .stash, .key, .none: break
            }
            return
        }
        switch input {
        case .submit:
            guard !dialogAnswered else { return }
            typedSinceReturn = false
            pendingSubmit = now
        case .stash:
            putIntoComposer()
            stashPending = true
        case .pick, .escape, .key, .text: putIntoComposer()
        case .none: break
        }
    }

    private mutating func putIntoComposer() {
        typedSinceSubmit = true
        typedSinceReturn = true
    }

    private mutating func answerDialog() {
        dialogOpen = false
        dialogAnswered = true
    }

    /// Send to session typed `prompt` into the composer with no Return (see the composer rule above).
    public mutating func prompted(_ prompt: String) {
        loamPrompt = prompt
        pendingSubmit = nil
    }

    /// A `UserPromptSubmit` from you, or one that looks the same. It takes the composer only after your Return.
    private mutating func tookSubmit(now: Date) {
        // A wall clock that steps back must not make an old Return look fresh.
        guard let pending = pendingSubmit, (0...Self.submitWindow).contains(now.timeIntervalSince(pending)) else { return }
        pendingSubmit = nil
        if stashPending {
            // The stash comes back into the composer, and it can hold the prompt that Loam typed.
            typedSinceSubmit = true
            stashPending = false
            return
        }
        typedSinceSubmit = typedSinceReturn
        if !typedSinceReturn { loamPrompt = nil }
    }

    /// The composer is empty: a new session started. A stash can come back into it.
    private mutating func emptyComposer(stashComesBack: Bool) {
        pendingSubmit = nil
        if stashPending, stashComesBack {
            typedSinceSubmit = true
            typedSinceReturn = true
            stashPending = false
            return
        }
        typedSinceSubmit = false
        typedSinceReturn = false
        stashPending = false
        loamPrompt = nil
    }

    /// Opens or closes the dialog for an event of the session (see the composer rule above).
    private mutating func followDialog(_ event: PaneEvent) {
        switch (event.event, event.notificationType) {
        case ("PermissionRequest", _), ("Notification", "elicitation_dialog"), ("Notification", "elicitation_url_dialog"):
            dialogOpen = true
            dialogAnswered = false
        case ("Notification", "permission_prompt"):
            if !dialogAnswered { dialogOpen = true }
        default:
            dialogOpen = false
            dialogAnswered = false
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
