import Foundation
import Testing

@testable import LoamKit

func paneEvent(_ name: String, _ id: String, source: String? = nil, notification: String? = nil) -> PaneEvent {
    PaneEvent(event: name, sessionID: id, cwd: "/tmp", at: "2026-10-03T09:00:00Z", source: source, notificationType: notification)
}

/// `#expect` cannot call a mutating method.
private func applied(_ session: inout PaneSession, _ event: PaneEvent) -> Bool { session.apply(event) }
private func typed(_ session: inout PaneSession) -> Bool { session.typed() }

/// The pane state machine (spec 8.4, phase 3 events): session ID, working or idle, ended.
@Suite struct PaneSessionTests {
    @Test func aSeededPaneRunsUntilItsSessionStarts() {
        var s = PaneSession(sessionID: "a")
        #expect(s.state == .running && !s.started)
        let changed = s.apply(paneEvent("SessionStart", "a", source: "startup"))
        #expect(changed)
        #expect(s.state == .idle && s.started && s.sessionID == "a")
    }

    @Test func aPromptMeansWorkingAndStopMeansIdle() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        s.apply(paneEvent("UserPromptSubmit", "a"))
        #expect(s.state == .working)
        s.apply(paneEvent("PostToolUse", "a"))
        #expect(s.state == .working)
        s.apply(paneEvent("Stop", "a"))
        #expect(s.state == .idle)
    }

    @Test func clearChangesTheSessionIDAndKeepsTheOldOne() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        s.apply(paneEvent("SessionEnd", "a"))
        #expect(s.state == .ended)
        s.apply(paneEvent("SessionStart", "b", source: "clear"))
        #expect(s.sessionID == "b" && s.state == .idle && !s.exited)
        #expect(s.pastSessionIDs == ["a"])
        #expect(s.ran("a") && s.ran("b") && !s.ran("c"))
    }

    @Test func aCompactInTheMiddleOfATurnKeepsWorking() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        s.apply(paneEvent("UserPromptSubmit", "a"))
        s.apply(paneEvent("SessionStart", "a", source: "compact"))
        #expect(s.state == .working && s.pastSessionIDs.isEmpty)
    }

    @Test func anEventOfAnotherSessionChangesNothing() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        #expect(!applied(&s, paneEvent("UserPromptSubmit", "other")))
        #expect(!applied(&s, paneEvent("SessionEnd", "other")))
        #expect(s.state == .idle)
    }

    @Test func unknownEventsChangeNothing() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        #expect(!applied(&s, paneEvent("SomeLaterEvent", "a")))
        #expect(!applied(&s, paneEvent("Notification", "a", notification: "idle_prompt")))
        #expect(!applied(&s, paneEvent("Notification", "a")))
        #expect(s.state == .idle)
    }

    @Test func theProcessExitEndsThePaneForGood() {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        s.processExited()
        #expect(s.state == .ended && s.exited)
        #expect(!applied(&s, paneEvent("SessionStart", "b", source: "startup")))
        #expect(s.sessionID == "a")
    }

    @Test func aPaneWithNoIDTakesTheFirstSession() {
        var s = PaneSession()
        s.apply(paneEvent("UserPromptSubmit", "x"))
        #expect(s.state == .working)
        s.apply(paneEvent("SessionStart", "x", source: "startup"))
        #expect(s.sessionID == "x" && s.pastSessionIDs.isEmpty)
    }
}

/// The alert states (spec 8.4): needs you and done, unread, and their clear rules.
@Suite struct PaneAttentionTests {
    private func started() -> PaneSession {
        var s = PaneSession(sessionID: "a")
        s.apply(paneEvent("SessionStart", "a", source: "startup"))
        s.apply(paneEvent("UserPromptSubmit", "a"))
        return s
    }

    @Test func aPermissionRequestNeedsYou() {
        var s = started()
        #expect(applied(&s, paneEvent("PermissionRequest", "a")))
        #expect(s.state == .needsYou && s.waitsOn == .permission)
    }

    @Test func onlyTheQuestionNotificationsNeedYou() {
        for (type, reason) in [("elicitation_dialog", NeedsYouReason.question), ("elicitation_url_dialog", .question),
                               ("agent_needs_input", .input)] {
            var s = started()
            s.apply(paneEvent("Notification", "a", notification: type))
            #expect(s.state == .needsYou && s.waitsOn == reason, "\(type)")
        }
        for type in ["idle_prompt", "auth_success", "agent_completed", "elicitation_complete", "elicitation_response"] {
            var s = started()
            #expect(!applied(&s, paneEvent("Notification", "a", notification: type)), "\(type)")
            #expect(s.state == .working)
        }
    }

    @Test func aPermissionPromptNotificationAloneNeedsYou() {
        var s = started()
        #expect(applied(&s, paneEvent("Notification", "a", notification: "permission_prompt")))
        #expect(s.state == .needsYou && s.waitsOn == .permission)
        s.typed()
        #expect(s.state == .working)
    }

    @Test func aPermissionPromptAfterAPermissionRequestChangesNothing() {
        var s = started()
        s.apply(paneEvent("PermissionRequest", "a"))
        #expect(!applied(&s, paneEvent("Notification", "a", notification: "permission_prompt")))
        #expect(s.state == .needsYou && s.waitsOn == .permission)
        var q = started()
        q.apply(paneEvent("Notification", "a", notification: "elicitation_dialog"))
        #expect(!applied(&q, paneEvent("Notification", "a", notification: "permission_prompt")))
        #expect(q.waitsOn == .question)
    }

    @Test func aPermissionPromptNeedsYouClearsOnALaterHook() {
        var s = started()
        s.apply(paneEvent("Notification", "a", notification: "permission_prompt"))
        s.apply(paneEvent("PostToolUse", "a"))
        #expect(s.state == .working)
        s.apply(paneEvent("Notification", "a", notification: "permission_prompt"))
        s.processExited()
        #expect(s.state == .ended)
    }

    @Test func aTurnThatStopsOnAnAPIErrorNeedsYou() {
        var s = started()
        s.apply(paneEvent("StopFailure", "a"))
        #expect(s.state == .needsYou && s.waitsOn == .apiError)
        #expect(!s.doneUnread)
    }

    @Test func needsYouClearsWhenTheSessionMovesOn() {
        for next in ["PostToolUse", "UserPromptSubmit"] {
            var s = started()
            s.apply(paneEvent("PermissionRequest", "a"))
            s.apply(paneEvent(next, "a"))
            #expect(s.state == .working && s.waitsOn == nil, "\(next)")
        }
        var s = started()
        s.apply(paneEvent("PermissionRequest", "a"))
        s.apply(paneEvent("Stop", "a"))
        #expect(s.state == .idle && s.waitsOn == nil)
    }

    @Test func typingClearsNeedsYou() {
        // A denied permission prompt sends no hook, so a key in the pane is the only sign.
        var s = started()
        #expect(!typed(&s))  // Working: nothing to clear.
        s.apply(paneEvent("PermissionRequest", "a"))
        #expect(typed(&s))
        #expect(s.state == .working && s.waitsOn == nil)
        // After an API error the turn is over, so a key gives idle.
        s.apply(paneEvent("StopFailure", "a"))
        #expect(typed(&s))
        #expect(s.state == .idle)
    }

    @Test func aCompactKeepsNeedsYou() {
        var s = started()
        s.apply(paneEvent("PermissionRequest", "a"))
        s.apply(paneEvent("SessionStart", "a", source: "compact"))
        #expect(s.state == .needsYou)
    }

    @Test func theEndClearsNeedsYou() {
        var s = started()
        s.apply(paneEvent("PermissionRequest", "a"))
        s.apply(paneEvent("SessionEnd", "a"))
        #expect(s.state == .ended && s.waitsOn == nil)
        var t = started()
        t.apply(paneEvent("PermissionRequest", "a"))
        t.processExited()
        #expect(t.state == .ended && t.waitsOn == nil)
        // A state set from outside, such as `Workspace.setState`, also clears the reason.
        var u = started()
        u.apply(paneEvent("PermissionRequest", "a"))
        u.state = .idle
        #expect(u.waitsOn == nil)
    }

    @Test func aFinishedTurnIsDoneUnread() {
        var s = started()
        #expect(!s.doneUnread)
        s.apply(paneEvent("Stop", "a"))
        #expect(s.state == .idle && s.doneUnread)
        // A new turn keeps the mark until you look at the pane.
        s.apply(paneEvent("UserPromptSubmit", "a"))
        #expect(s.doneUnread)
    }

    @Test func anEventOfAnotherSessionRaisesNoAlert() {
        var s = started()
        #expect(!applied(&s, paneEvent("PermissionRequest", "other")))
        #expect(!applied(&s, paneEvent("Stop", "other")))
        #expect(s.state == .working && !s.doneUnread)
    }
}

@Suite struct PaneCommandTests {
    @Test func aSeededPaneExecsLoamStartInALoginShell() {
        let command = PaneCommand.start(shell: "/bin/zsh", loam: "/Users/me/.local/bin/loam", plot: "k3v9q2mxa7", sessionID: "1111-2222")
        #expect(command == "/bin/zsh -lc 'exec /Users/me/.local/bin/loam start k3v9q2mxa7 --session-id 1111-2222'")
    }

    @Test func theRepoGoesBeforeTheSessionID() {
        let command = PaneCommand.start(shell: "/bin/zsh", loam: "loam", plot: "p", repo: "web", sessionID: "s")
        #expect(command == "/bin/zsh -lc 'exec loam start p --repo web --session-id s'")
    }

    /// Ticket 93: a plot session starts in the plot folder.
    @Test func aPlotSessionPassesPlotFolder() {
        let command = PaneCommand.start(shell: "/bin/zsh", loam: "loam", plot: "p", plotFolder: true, sessionID: "s")
        #expect(command == "/bin/zsh -lc 'exec loam start p --plot-folder --session-id s'")
    }

    @Test func resumeExecsLoamResume() {
        #expect(PaneCommand.resume(shell: "/bin/bash", loam: "loam", sessionID: "s") == "/bin/bash -lc 'exec loam resume s'")
    }

    @Test func pathsWithSpacesAndQuotesSurviveTwoShells() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pane-command-\(UUID().uuidString)/My Loam/it's")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let loam = dir.appendingPathComponent("loam").path
        try FakeScript.install("#!/bin/sh\nprintf '%s\\n' ran \"$@\"\n", at: URL(fileURLWithPath: loam))
        let command = PaneCommand.start(shell: "/bin/sh", loam: loam, plot: "p", sessionID: "s")
        // The outer shell (libghostty's) parses the line, then the login shell runs the inner one.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let words = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(words == ["ran", "start", "p", "--session-id", "s"])
    }

    @Test func theShellComesFromSHELL() {
        #expect(PaneCommand.userShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]) == "/opt/homebrew/bin/fish")
        #expect(PaneCommand.userShell(environment: [:]) == "/bin/zsh")
    }
}
