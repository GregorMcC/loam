import Foundation
import Testing

@testable import LoamKit

/// Ticket 32: the alert states in the app model (spec 8.4). Needs you and done, unread, their clear
/// rules, ⌘L, the banner and the Dock badge, and done, unread in `state.json`.
@MainActor
@Suite struct AttentionTests {
    func plot(_ id: String) -> PlotSummary {
        PlotSummary(id: id, name: "Plot \(id)", what: "", createdAt: "2026-01-01T00:00:00Z")
    }

    func event(_ name: String, _ id: String, notification: String? = nil) -> PaneEvent {
        PaneEvent(event: name, sessionID: id, cwd: "/tmp", at: "2026-10-03T09:00:00Z", source: nil, notificationType: notification)
    }

    /// A model with plots A, B, and C. Each holds one seeded pane that started. A is active.
    func model(frontmost: Bool = true) -> (model: AppModel, a: PaneID, b: PaneID, c: PaneID) {
        let model = AppModel(client: LoamClient(binary: URL(fileURLWithPath: "/opt/loam/bin/loam"), environment: [:]))
        model.shell = "/bin/zsh"
        model.isFrontmost = { frontmost }
        model.apply([plot("A"), plot("B"), plot("C")])
        var panes: [PaneID] = []
        for id in ["C", "B", "A"] {
            model.activate(plot: id)
            model.openTab(.session)
            let pane = model.workspace.focusedPane!
            let session = model.workspace.spec(of: pane)!.sessionID!
            model.apply(event("SessionStart", session), to: pane)
            panes.insert(pane, at: 0)
        }
        return (model, panes[0], panes[1], panes[2])
    }

    func send(_ model: AppModel, _ name: String, to pane: PaneID, notification: String? = nil) {
        model.apply(event(name, model.workspace.session(of: pane)!.sessionID!, notification: notification), to: pane)
    }

    // MARK: Done, unread

    @Test func aTurnThatEndsWhileYouLookAtThePaneIsRead() {
        let (model, a, _, _) = model()
        send(model, "UserPromptSubmit", to: a)
        send(model, "Stop", to: a)
        #expect(model.workspace.attention(of: a) == .none)
    }

    @Test func aTurnThatEndsInAnotherPlotIsDoneUnreadUntilYouShowIt() {
        let (model, _, b, _) = model()
        send(model, "UserPromptSubmit", to: b)
        send(model, "Stop", to: b)
        #expect(model.workspace.attention(of: b) == .doneUnread)
        model.activate(plot: "B")
        #expect(model.workspace.attention(of: b) == .none)
    }

    @Test func aPaneInAnotherTabOrSplitIsDoneUnreadUntilYouFocusIt() {
        let (model, a, _, _) = model()
        model.split(.sideBySide, .session)
        let right = model.workspace.focusedPane!
        model.apply(event("SessionStart", model.workspace.spec(of: right)!.sessionID!), to: right)
        send(model, "Stop", to: a)
        #expect(model.workspace.attention(of: a) == .doneUnread)
        model.focus(a)
        #expect(model.workspace.attention(of: a) == .none)
    }

    @Test func whileAnotherAppIsFrontmostTheFocusedPaneIsDoneUnreadUntilLoamIsFrontmost() {
        var frontmost = false
        let (model, a, _, _) = model()
        model.isFrontmost = { frontmost }
        send(model, "Stop", to: a)
        #expect(model.workspace.attention(of: a) == .doneUnread)
        model.frontmostChanged()
        #expect(model.workspace.attention(of: a) == .doneUnread)
        frontmost = true
        model.frontmostChanged()
        #expect(model.workspace.attention(of: a) == .none)
    }

    @Test func doneUnreadGoesToStateJSON() throws {
        let file = AppStateFile(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("loam-attention-\(UUID().uuidString)/state.json"))
        let model = AppModel(client: LoamClient(binary: URL(fileURLWithPath: "/opt/loam/bin/loam"), environment: [:]))
        model.isFrontmost = { true }
        model.startRestore(from: file, writeDelay: .milliseconds(10))
        model.apply([plot("A"), plot("B")])
        model.activate(plot: "B")
        model.openTab(.session)
        let pane = try #require(model.workspace.focusedPane)
        model.apply(event("SessionStart", model.workspace.spec(of: pane)!.sessionID!), to: pane)
        model.activate(plot: "A")
        send(model, "Stop", to: pane)
        model.stateWriter?.flush()
        #expect(SavedLayout.read(from: file).panes.first { $0.id == pane }?.doneUnread == true)
        model.activate(plot: "B")
        model.stateWriter?.flush()
        #expect(SavedLayout.read(from: file).panes.first { $0.id == pane }?.doneUnread == false)
    }

    // MARK: Needs you

    @Test func aGlanceDoesNotClearNeedsYou() {
        let (model, _, b, _) = model()
        send(model, "PermissionRequest", to: b)
        #expect(model.workspace.attention(of: b) == .needsYou)
        model.activate(plot: "B")
        model.frontmostChanged()
        #expect(model.workspace.attention(of: b) == .needsYou)
    }

    @Test func typingInThePaneClearsNeedsYou() {
        let (model, a, b, _) = model()
        send(model, "PermissionRequest", to: b)
        model.typed(in: a)  // Another pane: nothing.
        #expect(model.workspace.attention(of: b) == .needsYou)
        model.typed(in: b)
        #expect(model.workspace.attention(of: b) == .none)
        #expect(model.workspace.state(of: b) == .working)
    }

    /// Text, Return, Escape, Delete, and Control keys answer a prompt. Keys that only move do not.
    @Test func onlyAKeyThatAnswersCountsAsTyping() {
        for typed in ["y", "1", "é", "\r", "\u{1B}", "\u{7F}", "\u{03}"] {
            #expect(TypingKey.clearsNeedsYou(typed), "\(typed.unicodeScalars.map(\.value))")
        }
        for moved in ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}", "\u{F72C}", "\u{F704}", "\t", "\u{19}", "", nil] {
            #expect(!TypingKey.clearsNeedsYou(moved), "\(String(describing: moved?.unicodeScalars.map(\.value)))")
        }
    }

    @Test func needsYouWinsOverDoneUnread() {
        let (model, _, b, _) = model()
        send(model, "Stop", to: b)
        send(model, "UserPromptSubmit", to: b)
        send(model, "Notification", to: b, notification: "elicitation_dialog")
        #expect(model.workspace.attention(of: b) == .needsYou)
        #expect(model.switcher.attention(b) == .needsYou)
    }

    @Test func theSwitcherReadsTheAttention() {
        let (model, _, b, c) = model()
        send(model, "Stop", to: b)
        send(model, "StopFailure", to: c)
        #expect(model.switcher.attention(b) == .doneUnread)
        #expect(model.switcher.attention(c) == .needsYou)
    }

    @Test func aShellPaneRaisesNoAlert() {
        let (model, _, _, _) = model()
        model.openTab(.shell, folder: "/tmp")
        let shell = model.workspace.focusedPane!
        model.apply(event("PermissionRequest", "x"), to: shell)
        model.apply(event("Stop", "x"), to: shell)
        #expect(model.workspace.attention(of: shell) == .none)
    }

    // MARK: ⌘L and the title bar button

    @Test func nextPaneThatNeedsYouGoesInSidebarOrderAndWraps() {
        let (model, a, b, c) = model()
        #expect(!model.goToNextPaneThatNeedsYou())
        send(model, "PermissionRequest", to: c)
        send(model, "PermissionRequest", to: b)
        #expect(model.needsYouPanes == [b, c])
        #expect(model.goToNextPaneThatNeedsYou())
        #expect(model.workspace.activePlotID == "B" && model.workspace.focusedPane == b)
        #expect(model.goToNextPaneThatNeedsYou())
        #expect(model.workspace.focusedPane == c)
        #expect(model.goToNextPaneThatNeedsYou())
        #expect(model.workspace.focusedPane == b)
        model.typed(in: b)
        model.typed(in: c)
        model.focus(a)
        #expect(!model.goToNextPaneThatNeedsYou())
    }

    @Test func theFocusedPaneAloneDoesNotMove() {
        let (model, a, _, _) = model()
        send(model, "PermissionRequest", to: a)
        #expect(!model.goToNextPaneThatNeedsYou())
        #expect(model.workspace.focusedPane == a)
    }

    @Test func elsewhereCountsOnlyOtherPlots() {
        let (model, a, _, c) = model()
        model.openTab(.session)
        let a2 = model.workspace.focusedPane!
        model.apply(event("SessionStart", model.workspace.spec(of: a2)!.sessionID!), to: a2)
        model.focus(a)
        send(model, "PermissionRequest", to: a2)
        #expect(model.elsewhereNeedYouCount == 0)
        send(model, "PermissionRequest", to: c)
        #expect(model.elsewhereNeedYouCount == 1)
        #expect(model.goToNextPaneThatNeedsYou(elsewhere: true))
        #expect(model.workspace.focusedPane == c)
    }

    @Test func aPermissionPromptAloneNeedsYou() {
        let (model, _, b, _) = model()
        send(model, "UserPromptSubmit", to: b)
        send(model, "Notification", to: b, notification: "permission_prompt")
        #expect(model.workspace.attention(of: b) == .needsYou)
        #expect(model.needsYouPanes == [b])
    }

    // MARK: Banner and Dock badge

    @Test func aBannerShowsOnlyWhileAnotherAppIsFrontmost() {
        var frontmost = true
        let (model, _, b, c) = model()
        model.isFrontmost = { frontmost }
        model.setTerminalTitle("Fix the login", of: b)
        let notifier = RecordingNotifier()
        model.notifier = notifier
        send(model, "PermissionRequest", to: c)
        #expect(notifier.banners.isEmpty)
        #expect(notifier.badge == 1)
        frontmost = false
        send(model, "PermissionRequest", to: b)
        #expect(notifier.banners == [AttentionBanner(pane: b, plotName: "Plot B", paneTitle: "Fix the login", reason: .permission)])
        #expect(notifier.banners.first?.title == "Needs you in Plot B")
        #expect(notifier.badge == 2)
        // Needs you again for the same wait is no new banner.
        send(model, "Notification", to: b, notification: "elicitation_dialog")
        #expect(notifier.banners.count == 1)
        // The permission_prompt that follows a PermissionRequest repeats the state: no second banner.
        send(model, "Notification", to: b, notification: "permission_prompt")
        #expect(notifier.banners.count == 1)
        #expect(notifier.badge == 2)
        // The session moves on: the banner goes and the badge counts 1.
        send(model, "PostToolUse", to: b)
        #expect(notifier.removed == [b])
        #expect(notifier.badge == 1)
        model.closePane(c)
        #expect(notifier.removed == [b, c])
        #expect(notifier.badge == 0)
    }

    @Test func aBlankTerminalTitleGivesTheBannerTheSpecTitle() {
        let (model, _, b, _) = model()
        model.isFrontmost = { false }
        model.setTerminalTitle("  ", of: b)
        let notifier = RecordingNotifier()
        model.notifier = notifier
        send(model, "PermissionRequest", to: b)
        #expect(notifier.banners.first?.subtitle == model.workspace.spec(of: b)?.title)
        #expect(notifier.banners.first?.subtitle.isEmpty == false)
    }

    @Test func aNewNotifierGetsTheBadgeAtOnce() {
        let (model, _, b, _) = model()
        send(model, "PermissionRequest", to: b)
        let notifier = RecordingNotifier()
        model.notifier = notifier
        #expect(notifier.badge == 1)
    }

    // MARK: The halo

    @Test func aPaneArrivesWhenItStartsToNeedYou() {
        let (model, _, b, _) = model()
        #expect(model.arrivingPanes().isEmpty)
        send(model, "PermissionRequest", to: b)
        #expect(model.arrivingPanes() == [b])
        #expect(model.arrivingPanes(at: Date().addingTimeInterval(AppModel.arrivalWindow + 1)).isEmpty)
        send(model, "PostToolUse", to: b)
        #expect(model.arrivingPanes().isEmpty)
    }
}
