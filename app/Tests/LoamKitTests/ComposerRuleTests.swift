import Foundation
import Testing

@testable import LoamKit

/// The rule for what the input of Claude Code can hold (ticket 110), on its own. Send to session types only into a
/// composer that holds none of your text. The times are made up: `t0` and seconds after it.
@Suite struct ComposerRuleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func session() -> PaneSession { PaneSession(sessionID: "s1", state: .idle, started: true) }

    // MARK: Your Return and its submit

    /// Your Return sends the composer, and the `UserPromptSubmit` that comes within 3 seconds takes it. Claude Code
    /// sends no source today. An event for another session changes nothing.
    @Test func aReturnAndItsSubmitEmptyTheComposer() {
        var session = session()
        session.input(.key, now: t0)
        session.loamPrompt = "Fix it."
        session.input(.submit, now: t0)
        #expect(session.typedSinceSubmit && !session.typedSinceReturn && session.pendingSubmit == t0)
        session.apply(paneEvent("UserPromptSubmit", "other"), now: t0.addingTimeInterval(1))
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it." && session.pendingSubmit == t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1))
        #expect(!session.typedSinceSubmit && !session.typedSinceReturn && session.loamPrompt == nil && session.pendingSubmit == nil)
    }

    @Test func aUserSourceIsTheSameAsNoSource() {
        var session = session()
        session.input(.key, now: t0)
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1", source: "user"), now: t0.addingTimeInterval(PaneSession.submitWindow))
        #expect(!session.typedSinceSubmit && session.pendingSubmit == nil)
    }

    /// A submit more than 3 seconds after your Return is not the submit of that Return.
    @Test func aSubmitAfterThreeSecondsChangesNothing() {
        var session = session()
        session.input(.key, now: t0)
        session.loamPrompt = "Fix it."
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(3.5))
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it.")
    }

    /// A wall clock that steps back cannot make an old Return look fresh: the submit must come after the Return.
    @Test func aSubmitBeforeTheReturnChangesNothing() {
        var session = session()
        session.input(.key, now: t0)
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(-1))
        #expect(session.typedSinceSubmit && session.pendingSubmit == t0)
    }

    /// A background task, a message from a peer or an auto-continuation starts a turn with a submit that looks like
    /// yours. With no Return before it, the prompt that Loam typed stays in the composer.
    @Test func aSubmitWithNoReturnKeepsTheComposer() {
        var session = session()
        session.loamPrompt = "Fix it."
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.apply(paneEvent("PostToolUse", "s1"), now: t0)
        session.apply(paneEvent("Stop", "s1"), now: t0)
        #expect(session.state == .idle && session.loamPrompt == "Fix it.")
    }

    /// Loam types its prompt with no Return. A Return before it cannot send it, so a turn that Claude Code starts
    /// soon after does not take it.
    @Test func aReturnBeforeLoamTypesDoesNotSendItsPrompt() {
        var session = session()
        session.input(.submit, now: t0)
        session.prompted("Fix it.")
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1))
        #expect(session.loamPrompt == "Fix it." && session.pendingSubmit == nil)
    }

    /// A submit with another source is a turn that Claude Code starts by itself. It keeps your Return armed for
    /// the submit of your own prompt.
    @Test func aSubmitWithAnotherSourceKeepsEverything() {
        for source in ["system", "sdk", "loop_wakeup", "schedule_wakeup", "poll_event"] {
            var session = session()
            session.input(.key, now: t0)
            session.loamPrompt = "Fix it."
            session.input(.submit, now: t0)
            session.apply(paneEvent("UserPromptSubmit", "s1", source: source), now: t0.addingTimeInterval(1))
            #expect(session.state == .working, "\(source)")
            #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it." && session.pendingSubmit == t0, "\(source)")
            session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(2))
            #expect(!session.typedSinceSubmit && session.loamPrompt == nil, "\(source)")
        }
    }

    /// Claude Code keeps a draft that you type during a turn and do not send, so a Stop changes nothing.
    @Test func theKeysOfATurnStillCountAfterItsStop() {
        var session = session()
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key, now: t0)
        session.apply(paneEvent("Stop", "s1"), now: t0.addingTimeInterval(5))
        #expect(session.state == .idle && session.typedSinceSubmit)
    }

    /// The hook line comes up to about 200 ms after your Return. A key in that time still counts.
    @Test func aKeyBeforeTheSubmitStillCounts() {
        var session = session()
        session.input(.key, now: t0)
        session.input(.submit, now: t0)
        session.input(.key, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(0.2))
        #expect(session.typedSinceSubmit && session.typedSinceReturn && session.pendingSubmit == nil)
    }

    /// A prompt that you send during a turn waits in a queue, and its submit comes when the queue drains. Later than
    /// 3 seconds, the flag stays: too careful, a known limit.
    @Test func aQueuedPromptThatDrainsLateKeepsTheFlag() {
        var session = session()
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key, now: t0)
        session.input(.submit, now: t0.addingTimeInterval(1))
        session.apply(paneEvent("PostToolUse", "s1"), now: t0.addingTimeInterval(5))
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(11))
        #expect(session.typedSinceSubmit && !session.typedSinceReturn)
    }

    // MARK: Dialogs

    /// A permission request, a question, or an elicitation opens a dialog that takes the keys. A key in it does not
    /// count, also after it ends needs you. The Return answers the dialog: it is not input and does not arm a submit.
    @Test func aReturnInADialogDoesNotArmTheSubmit() {
        var session = session()
        session.input(.key, now: t0)
        session.input(.submit, now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key, now: t0)  // Draft D.
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0.addingTimeInterval(1))
        #expect(session.dialogOpen && session.state == .needsYou)
        session.typed()
        #expect(session.dialogOpen && session.state == .working)
        session.input(.key, now: t0)
        session.input(.submit, now: t0.addingTimeInterval(2))
        #expect(session.typedSinceReturn && session.pendingSubmit == nil)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(3))
        #expect(session.typedSinceSubmit)
    }

    /// A paste, a drop, or dictated text counts, also while a dialog is open. Too careful is fine there.
    @Test func aPasteCountsInADialog() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.key, now: t0)
        #expect(!session.typedSinceSubmit)
        session.input(.text, now: t0)
        #expect(session.typedSinceSubmit && session.typedSinceReturn)
    }

    /// The events that open a dialog. `agent_needs_input` and an API error open none, because their keys can go to
    /// the composer.
    @Test func theEventsThatOpenADialog() {
        let opens: [(String, String?)] = [("PermissionRequest", nil), ("Notification", "elicitation_dialog"),
                                          ("Notification", "elicitation_url_dialog"), ("Notification", "permission_prompt")]
        for (event, notification) in opens {
            var session = session()
            session.apply(paneEvent(event, "s1", notification: notification), now: t0)
            #expect(session.dialogOpen, "\(event) \(String(describing: notification))")
        }
        for (event, notification) in [("StopFailure", nil), ("Notification", "agent_needs_input")] as [(String, String?)] {
            var session = session()
            session.apply(paneEvent(event, "s1", notification: notification), now: t0)
            session.input(.key, now: t0)
            #expect(!session.dialogOpen && session.typedSinceSubmit, "\(event) \(String(describing: notification))")
        }
    }

    /// The next hook event of the session closes the dialog: a tool that ends or fails, an answered question, and
    /// also an event that Loam does not know. A key that does not answer does not, and neither does an event of
    /// another session.
    @Test func theNextHookEventClosesTheDialog() {
        let closes: [(String, String?)] = [("PostToolUse", nil), ("PostToolUseFailure", nil), ("UserPromptSubmit", nil),
                                           ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
                                           ("SessionStart", "compact"), ("Notification", "agent_needs_input"),
                                           ("Notification", "elicitation_response"), ("Notification", "elicitation_complete"),
                                           ("SomethingNew", nil)]
        for (event, value) in closes {
            var session = session()
            session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
            session.typed()
            session.input(.key, now: t0)
            session.apply(paneEvent("Stop", "other"), now: t0)
            #expect(session.dialogOpen, "\(event)")
            let source = event == "SessionStart" ? value : nil
            let notification = event == "Notification" ? value : nil
            session.apply(paneEvent(event, "s1", source: source, notification: notification), now: t0)
            #expect(!session.dialogOpen, "\(event)")
        }
        var exited = session()
        exited.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        exited.processExited()
        #expect(!exited.dialogOpen)
    }

    /// After the dialog, the keys count again.
    @Test func theKeysCountAfterTheDialogCloses() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.key, now: t0)
        #expect(!session.typedSinceSubmit && !session.typedSinceReturn)
        session.apply(paneEvent("PostToolUse", "s1"), now: t0)
        session.input(.key, now: t0)
        #expect(session.typedSinceSubmit)
    }

    // MARK: The answer key

    /// You approve with 1, and the tool runs for a long time. Your keys in that time go to the composer, so they
    /// count, and the draft blocks Send after the Stop.
    @Test func aDigitAnswersTheDialogAndTheKeysAfterItCount() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.pick, now: t0)
        #expect(!session.dialogOpen && !session.typedSinceSubmit && session.pendingSubmit == nil)
        session.input(.key, now: t0.addingTimeInterval(1))
        #expect(session.typedSinceSubmit && session.typedSinceReturn)
        session.apply(paneEvent("PostToolUse", "s1"), now: t0.addingTimeInterval(60))
        session.apply(paneEvent("Stop", "s1"), now: t0.addingTimeInterval(61))
        #expect(session.state == .idle && session.typedSinceSubmit)
    }

    /// A Return that approves is not your submit: the submit of the turn that goes on does not take the composer.
    @Test func aReturnThatAnswersDoesNotArmTheSubmit() {
        var session = session()
        session.loamPrompt = "Fix it."
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.submit, now: t0)
        #expect(!session.dialogOpen && session.pendingSubmit == nil && !session.typedSinceSubmit)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1))
        #expect(session.loamPrompt == "Fix it.")
    }

    /// Escape denies the dialog. It counts as input: the state is working anyway, and an Escape that stops a turn
    /// can put a queued prompt back into the composer.
    @Test func anEscapeThatDeniesCounts() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.escape, now: t0)
        #expect(!session.dialogOpen && session.typedSinceSubmit && session.typedSinceReturn)
    }

    /// Claude Code sends `permission_prompt` 6 seconds after a dialog opens, and cancels it when the dialog closes.
    /// It can still come after your answer key, and then it does not open the dialog again. The next
    /// `PermissionRequest` or any other event ends that, so a later dialog opens as before.
    @Test func aLatePermissionPromptDoesNotReopenTheDialog() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.pick, now: t0.addingTimeInterval(5.9))
        session.apply(paneEvent("Notification", "s1", notification: "permission_prompt"), now: t0.addingTimeInterval(6))
        #expect(!session.dialogOpen)
        session.input(.key, now: t0.addingTimeInterval(7))
        #expect(session.typedSinceSubmit)

        var next = session
        next.apply(paneEvent("PermissionRequest", "s1"), now: t0.addingTimeInterval(8))
        #expect(next.dialogOpen)
        var other = session
        other.apply(paneEvent("PostToolUse", "s1"), now: t0.addingTimeInterval(8))
        other.apply(paneEvent("Notification", "s1", notification: "permission_prompt"), now: t0.addingTimeInterval(9))
        #expect(other.dialogOpen)
    }

    /// The first answer key ends the dialog for Loam. A question with several parts takes more keys, and those
    /// count: too careful, a known limit.
    @Test func theKeysOfALaterPartOfAQuestionCount() {
        var session = session()
        session.apply(paneEvent("Notification", "s1", notification: "elicitation_dialog"), now: t0)
        session.input(.key, now: t0)  // An arrow key moves to an option.
        session.input(.pick, now: t0)
        #expect(!session.dialogOpen && !session.typedSinceSubmit)
        session.input(.pick, now: t0)  // The second part.
        #expect(session.typedSinceSubmit)
    }

    // MARK: The stash

    /// ⌃S stashes the draft. Claude Code puts it back into the composer when you submit, so the submit of the next
    /// prompt leaves the flag set. The submit after that clears it as usual.
    @Test func aStashedDraftComesBackAfterTheSubmit() {
        var session = session()
        session.input(.key, now: t0)  // Draft D.
        session.input(.stash, now: t0)
        #expect(session.stashPending && session.typedSinceSubmit)
        session.input(.key, now: t0)  // Q.
        session.input(.submit, now: t0.addingTimeInterval(1))
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1.2))
        #expect(session.typedSinceSubmit && !session.stashPending && session.pendingSubmit == nil)
        session.apply(paneEvent("Stop", "s1"), now: t0.addingTimeInterval(5))
        session.input(.submit, now: t0.addingTimeInterval(6))
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(6.2))
        #expect(!session.typedSinceSubmit)
    }

    /// The stash also comes back after `/clear`, so its `SessionStart` leaves the flag set.
    @Test func aStashedDraftComesBackAfterAClear() {
        var session = session()
        session.input(.key, now: t0)
        session.input(.stash, now: t0)
        session.input(.submit, now: t0.addingTimeInterval(1))  // `/clear`.
        session.apply(paneEvent("SessionStart", "s2", source: "clear"), now: t0.addingTimeInterval(1.2))
        #expect(session.typedSinceSubmit && !session.stashPending)
        session.input(.submit, now: t0.addingTimeInterval(2))
        session.apply(paneEvent("UserPromptSubmit", "s2"), now: t0.addingTimeInterval(2.2))
        #expect(!session.typedSinceSubmit)
    }

    /// The stash can hold the prompt that Loam typed, so Loam keeps it in mind until the next submit.
    @Test func aStashKeepsLoamsPrompt() {
        var session = session()
        session.prompted("Fix it.")
        session.input(.stash, now: t0)
        session.input(.key, now: t0)
        session.input(.submit, now: t0.addingTimeInterval(1))
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1.2))
        #expect(session.loamPrompt == "Fix it.")
    }

    /// The dialog takes ⌃S, so it does nothing there.
    @Test func aStashInADialogDoesNothing() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.stash, now: t0)
        #expect(!session.stashPending && !session.typedSinceSubmit && session.dialogOpen)
    }

    // MARK: New sessions

    /// A start, a resume and `/clear` begin with an empty composer. A compact and a fork keep it, because the text
    /// can still be there.
    @Test func aNewSessionEmptiesTheComposerAndACompactOrAForkKeepsIt() {
        for source in ["startup", "resume", "clear"] {
            var session = session()
            session.input(.key, now: t0)
            session.loamPrompt = "Fix it."
            session.input(.submit, now: t0)
            session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
            session.apply(paneEvent("SessionStart", "s2", source: source), now: t0)
            #expect(!session.typedSinceSubmit && !session.typedSinceReturn && session.loamPrompt == nil, "\(source)")
            #expect(session.pendingSubmit == nil && !session.dialogOpen, "\(source)")
        }
        for source in ["compact", "fork", "something-new"] {
            var session = session()
            session.input(.key, now: t0)
            session.loamPrompt = "Fix it."
            session.apply(paneEvent("SessionStart", "s2", source: source), now: t0)
            #expect(session.typedSinceSubmit && session.typedSinceReturn && session.loamPrompt == "Fix it.", "\(source)")
        }
    }
}

/// How the terminal view sorts a key down for the composer rule (ticket 110).
@Suite struct PaneInputTests {
    let returnKey: UInt16 = 0x24
    let enterKey: UInt16 = 0x4C
    let escapeKey: UInt16 = 0x35
    let oneKey: UInt16 = 0x12  // "1" on a US layout, "&" on AZERTY.

    func key(_ code: UInt16, _ characters: String? = nil, _ mods: KeyChord.Mods = [], isARepeat: Bool = false,
             composing: Bool = false) -> PaneInput {
        PaneInput(keyCode: code, characters: characters, mods: mods, isARepeat: isARepeat, composing: composing)
    }

    @Test func aPlainReturnSendsTheInput() {
        #expect(key(returnKey, "\r") == .submit)
        #expect(key(enterKey, "\u{3}") == .submit)
    }

    /// A held Return sends nothing more. ⇧ or ⌥ with Return adds a line, and Return in an input method ends the
    /// composition.
    @Test func otherReturnsAreNotASubmit() {
        #expect(key(returnKey, "\r", isARepeat: true) == .none)
        #expect(key(returnKey, "\r", [.shift]) == .key)
        #expect(key(returnKey, "\r", [.option]) == .key)
        #expect(key(returnKey, "\r", composing: true) == .key)
    }

    @Test func aKeyWithNoCommandIsInput() {
        for (code, characters) in [(0x00, "a"), (0x7E, "\u{F700}"), (0x30, "\t"), (0x33, "\u{7F}")] as [(UInt16, String)] {
            #expect(key(code, characters) == .key, "\(code)")
            #expect(key(code, characters, [.control], isARepeat: true) == .key, "\(code)")
        }
    }

    /// Escape denies a dialog. In an input method it ends the composition.
    @Test func escapeIsItsOwnKind() {
        #expect(key(escapeKey, "\u{1B}") == .escape)
        #expect(key(escapeKey, "\u{1B}", [.control]) == .escape)
        #expect(key(escapeKey, "\u{1B}", composing: true) == .key)
        #expect(key(escapeKey, "\u{1B}", [.command]) == .none)
    }

    /// A digit 1 to 9 picks an option of a dialog. Loam reads the typed character, not the key code, because
    /// AZERTY needs ⇧ for a digit.
    @Test func aDigitIsReadByItsCharacter() {
        #expect(key(oneKey, "1") == .pick)
        #expect(key(oneKey, "!", [.shift]) == .key)
        #expect(key(oneKey, "&") == .key)
        #expect(key(oneKey, "1", [.shift]) == .pick)
        #expect(key(0x5C, "9") == .pick)  // The keypad.
        #expect(key(0x1D, "0") == .key)
        #expect(key(oneKey, "1", [.control]) == .key)
        #expect(key(oneKey, "1", [.command]) == .none)
        #expect(key(oneKey, "1", composing: true) == .key)
        #expect(key(oneKey, "1\u{20E3}") == .key)
    }

    /// ⌃S stashes the draft of Claude Code. Loam reads the control character, so the key of S on any layout works.
    @Test func controlSIsTheStash() {
        #expect(key(0x01, "\u{13}", [.control]) == .stash)
        #expect(key(0x01, "\u{13}", [.control], isARepeat: true) == .stash)
        #expect(key(0x01, "\u{13}", [.control, .shift]) == .key)
        #expect(key(0x01, "\u{13}", [.control], composing: true) == .key)
        #expect(key(0x01, "s") == .key)
        #expect(key(0x01, "s", [.command]) == .none)
    }

    /// ⌘ keys scroll, change the font size, clear the screen or move the focus, so they leave the input as it is.
    /// ⌘⌫ and ⌘⌦ clear the line, so they count.
    @Test func ofTheCommandKeysOnlyTheDeleteKeysAreInput() {
        for code: UInt16 in [0x7E, 0x7D, 0x7B, 0x7C, 0x28, 0x18, 0x1B, 0x1D, 0x24] {  // arrows, K, =, -, 0, Return
            #expect(key(code, nil, [.command]) == .none, "\(code)")
            #expect(key(code, nil, [.command, .option]) == .none, "\(code)")
        }
        #expect(key(returnKey, "\r", [.command, .shift]) == .none)
        #expect(key(0x33, "\u{7F}", [.command]) == .key)
        #expect(key(0x75, "\u{F728}", [.command]) == .key)
    }
}
