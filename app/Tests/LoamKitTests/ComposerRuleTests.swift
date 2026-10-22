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
        session.input(.key)
        session.loamPrompt = "Fix it."
        session.pressedReturn(now: t0)
        #expect(session.typedSinceSubmit && !session.typedSinceReturn && session.pendingSubmit == t0)
        session.apply(paneEvent("UserPromptSubmit", "other"), now: t0.addingTimeInterval(1))
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it." && session.pendingSubmit == t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(1))
        #expect(!session.typedSinceSubmit && !session.typedSinceReturn && session.loamPrompt == nil && session.pendingSubmit == nil)
    }

    @Test func aUserSourceIsTheSameAsNoSource() {
        var session = session()
        session.input(.key)
        session.pressedReturn(now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1", source: "user"), now: t0.addingTimeInterval(PaneSession.submitWindow))
        #expect(!session.typedSinceSubmit && session.pendingSubmit == nil)
    }

    /// A submit more than 3 seconds after your Return is not the submit of that Return.
    @Test func aSubmitAfterThreeSecondsChangesNothing() {
        var session = session()
        session.input(.key)
        session.loamPrompt = "Fix it."
        session.pressedReturn(now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(3.5))
        #expect(session.typedSinceSubmit && session.loamPrompt == "Fix it.")
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

    /// A submit with another source is a turn that Claude Code starts by itself. It keeps your Return armed for
    /// the submit of your own prompt.
    @Test func aSubmitWithAnotherSourceKeepsEverything() {
        for source in ["system", "sdk", "loop_wakeup", "schedule_wakeup", "poll_event"] {
            var session = session()
            session.input(.key)
            session.loamPrompt = "Fix it."
            session.pressedReturn(now: t0)
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
        session.pressedReturn(now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key)
        session.apply(paneEvent("Stop", "s1"), now: t0.addingTimeInterval(5))
        #expect(session.state == .idle && session.typedSinceSubmit)
    }

    /// The hook line comes up to about 200 ms after your Return. A key in that time still counts.
    @Test func aKeyBeforeTheSubmitStillCounts() {
        var session = session()
        session.input(.key)
        session.pressedReturn(now: t0)
        session.input(.key)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(0.2))
        #expect(session.typedSinceSubmit && session.typedSinceReturn && session.pendingSubmit == nil)
    }

    /// A prompt that you send during a turn waits in a queue, and its submit comes when the queue drains. Later than
    /// 3 seconds, the flag stays: too careful, a known limit.
    @Test func aQueuedPromptThatDrainsLateKeepsTheFlag() {
        var session = session()
        session.pressedReturn(now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key)
        session.pressedReturn(now: t0.addingTimeInterval(1))
        session.apply(paneEvent("PostToolUse", "s1"), now: t0.addingTimeInterval(5))
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(11))
        #expect(session.typedSinceSubmit && !session.typedSinceReturn)
    }

    // MARK: Dialogs

    /// A permission request, a question, or an elicitation opens a dialog that takes the keys. A key and a Return
    /// in it do not count and do not arm a submit, also after the first key ends needs you.
    @Test func aReturnInADialogDoesNotArmTheSubmit() {
        var session = session()
        session.input(.key)
        session.pressedReturn(now: t0)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0)
        session.input(.key)  // Draft D.
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0.addingTimeInterval(1))
        #expect(session.dialogOpen && session.state == .needsYou)
        session.typed()
        #expect(session.dialogOpen && session.state == .working)
        session.input(.key)
        session.pressedReturn(now: t0.addingTimeInterval(2))
        #expect(session.typedSinceReturn && session.pendingSubmit == nil)
        session.apply(paneEvent("UserPromptSubmit", "s1"), now: t0.addingTimeInterval(3))
        #expect(session.typedSinceSubmit)
    }

    /// A paste, a drop, or dictated text counts, also while a dialog is open. Too careful is fine there.
    @Test func aPasteCountsInADialog() {
        var session = session()
        session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
        session.input(.key)
        #expect(!session.typedSinceSubmit)
        session.input(.text)
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
            session.input(.key)
            #expect(!session.dialogOpen && session.typedSinceSubmit, "\(event) \(String(describing: notification))")
        }
    }

    /// The next hook event of the session closes the dialog, also an event that Loam does not know. A key does not,
    /// and neither does an event of another session.
    @Test func theNextHookEventClosesTheDialog() {
        let closes: [(String, String?)] = [("PostToolUse", nil), ("PreToolUse", nil), ("PostToolUseFailure", nil),
                                           ("UserPromptSubmit", nil), ("Stop", nil), ("StopFailure", nil),
                                           ("SessionEnd", nil), ("SessionStart", "compact"), ("Notification", "agent_needs_input")]
        for (event, value) in closes {
            var session = session()
            session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
            session.typed()
            session.input(.key)
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
        session.input(.key)
        session.apply(paneEvent("PostToolUse", "s1"), now: t0)
        session.input(.key)
        #expect(session.typedSinceSubmit)
    }

    // MARK: New sessions

    /// A start, a resume and `/clear` begin with an empty composer. A compact and a fork keep it, because the text
    /// can still be there.
    @Test func aNewSessionEmptiesTheComposerAndACompactOrAForkKeepsIt() {
        for source in ["startup", "resume", "clear"] {
            var session = session()
            session.input(.key)
            session.loamPrompt = "Fix it."
            session.pressedReturn(now: t0)
            session.apply(paneEvent("PermissionRequest", "s1"), now: t0)
            session.apply(paneEvent("SessionStart", "s2", source: source), now: t0)
            #expect(!session.typedSinceSubmit && !session.typedSinceReturn && session.loamPrompt == nil, "\(source)")
            #expect(session.pendingSubmit == nil && !session.dialogOpen, "\(source)")
        }
        for source in ["compact", "fork", "something-new"] {
            var session = session()
            session.input(.key)
            session.loamPrompt = "Fix it."
            session.apply(paneEvent("SessionStart", "s2", source: source), now: t0)
            #expect(session.typedSinceSubmit && session.typedSinceReturn && session.loamPrompt == "Fix it.", "\(source)")
        }
    }
}

/// What a key down in a terminal does to the composer of Claude Code (ticket 110).
@Suite struct InputKeyTests {
    let returnKey: UInt16 = 0x24
    let enterKey: UInt16 = 0x4C

    @Test func aPlainReturnSendsTheInput() {
        #expect(InputKey(keyCode: returnKey, mods: [], isARepeat: false, composing: false) == .submit)
        #expect(InputKey(keyCode: enterKey, mods: [], isARepeat: false, composing: false) == .submit)
    }

    /// A held Return sends nothing more. ⇧ or ⌥ with Return adds a line, and Return in an input method ends the
    /// composition.
    @Test func otherReturnsAreNotASubmit() {
        #expect(InputKey(keyCode: returnKey, mods: [], isARepeat: true, composing: false) == .none)
        #expect(InputKey(keyCode: returnKey, mods: [.shift], isARepeat: false, composing: false) == .input)
        #expect(InputKey(keyCode: returnKey, mods: [.option], isARepeat: false, composing: false) == .input)
        #expect(InputKey(keyCode: returnKey, mods: [], isARepeat: false, composing: true) == .input)
    }

    @Test func aKeyWithNoCommandIsInput() {
        for code: UInt16 in [0x00, 0x7E, 0x30, 0x33, 0x35] {  // a, Up, Tab, Delete, Escape
            #expect(InputKey(keyCode: code, mods: [], isARepeat: false, composing: false) == .input, "\(code)")
            #expect(InputKey(keyCode: code, mods: [.control], isARepeat: true, composing: false) == .input, "\(code)")
        }
    }

    /// ⌘ keys scroll, change the font size, clear the screen or move the focus, so they leave the input as it is.
    /// ⌘⌫ and ⌘⌦ clear the line, so they count.
    @Test func ofTheCommandKeysOnlyTheDeleteKeysAreInput() {
        for code: UInt16 in [0x7E, 0x7D, 0x7B, 0x7C, 0x28, 0x18, 0x1B, 0x1D, 0x24] {  // arrows, K, =, -, 0, Return
            #expect(InputKey(keyCode: code, mods: [.command], isARepeat: false, composing: false) == .none, "\(code)")
            #expect(InputKey(keyCode: code, mods: [.command, .option], isARepeat: false, composing: false) == .none, "\(code)")
        }
        #expect(InputKey(keyCode: 0x24, mods: [.command, .shift], isARepeat: false, composing: false) == .none)
        #expect(InputKey(keyCode: 0x33, mods: [.command], isARepeat: false, composing: false) == .input)
        #expect(InputKey(keyCode: 0x75, mods: [.command], isARepeat: false, composing: false) == .input)
    }
}
