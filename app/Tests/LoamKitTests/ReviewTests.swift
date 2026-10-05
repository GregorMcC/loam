import Foundation
import Testing
@testable import LoamKit

private func change(
    _ id: Int, plot: String = "p1", _ actor: Actor, at: String = "2026-10-02T09:05:00Z",
    entries: [ChangeEntry] = [ChangeEntry(item: "what", field: "value", old: "a", new: "b")], undoOf: Int? = nil
) -> Change {
    Change(id: id, plotID: plot, at: at, actor: actor, entries: entries, undoOf: undoOf)
}

private let you = Actor(kind: .app, sessionID: nil, loamStarted: nil)
private let cli = Actor(kind: .cli, sessionID: nil, loamStarted: nil)
private let claude = Actor(kind: .session, sessionID: "abcdef123456", loamStarted: true)
private let outside = Actor(kind: .session, sessionID: "fedcba654321", loamStarted: false)

private func tempState() -> AppStateFile {
    AppStateFile(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("state-\(UUID().uuidString)/state.json"))
}

@Suite struct WordDiffTests {
    @Test func marksRemovedAndAddedWords() {
        let d = WordDiff.diff(old: "Build the panel today", new: "Build the new panel")
        #expect(d == [
            .init(.same, "Build the"), .init(.added, "new"), .init(.same, "panel"), .init(.removed, "today"),
        ])
    }

    @Test func equalTextIsOneSameSegment() {
        #expect(WordDiff.diff(old: "a  b\nc", new: "a b c") == [.init(.same, "a b c")])
    }

    @Test func emptyOldIsAllAdded() {
        #expect(WordDiff.diff(old: "", new: "one two") == [.init(.added, "one two")])
        #expect(WordDiff.diff(old: "one two", new: "") == [.init(.removed, "one two")])
    }

    @Test func replacedWordShowsRemovedThenAdded() {
        let d = WordDiff.diff(old: "x old y", new: "x new y")
        #expect(d.map(\.kind) == [.same, .removed, .added, .same])
    }
}

@Suite struct ActorLabelTests {
    @Test func youInTheApp() { #expect(ActorLabel.make(you, pane: nil).text == "You") }
    @Test func youInTheCLI() { #expect(ActorLabel.make(cli, pane: nil).text == "You \u{00B7} CLI") }

    @Test func seededSessionShowsThePaneName() {
        let pane = PaneRef(id: PaneID(), name: "claude \u{00B7} app layout")
        let label = ActorLabel.make(claude, pane: pane)
        #expect(label.text == "claude \u{00B7} app layout")
        #expect(label.pane == pane)
    }

    @Test func seededSessionWithoutAPaneHasNoClick() {
        let label = ActorLabel.make(claude, pane: nil)
        #expect(label.pane == nil)
        #expect(label.text == "claude \u{00B7} abcdef")
    }

    @Test func outsideSessionShowsSixCharactersAndTheFullIDOnHover() {
        let label = ActorLabel.make(outside, pane: PaneRef(id: PaneID(), name: "ignored"))
        #expect(label.text == "claude \u{00B7} outside Loam fedcba")
        #expect(label.hover == "fedcba654321")
        #expect(label.pane == nil)
    }
}

@Suite struct ChangeRulesTests {
    @Test func onlyOthersChangesCountAsNew() {
        #expect(!ChangeRules.isNew(change(5, you), lastSeen: 0))
        #expect(!ChangeRules.isNew(change(5, cli), lastSeen: 0))
        #expect(ChangeRules.isNew(change(5, claude), lastSeen: 4))
        #expect(ChangeRules.isNew(change(5, outside), lastSeen: 0))
    }

    @Test func aSeenChangeIsNotNew() {
        #expect(!ChangeRules.isNew(change(5, claude), lastSeen: 5))
        #expect(!ChangeRules.isNew(change(5, claude), lastSeen: 9))
    }

    @Test func newChangesAreNewestFirstAndPerPlot() {
        let log = [change(1, claude), change(2, you), change(3, outside), change(4, plot: "p2", claude)]
        #expect(ChangeRules.newChanges(in: log, plot: "p1", lastSeen: 0).map(\.id) == [3, 1])
        #expect(ChangeRules.newChanges(in: log, plot: "p1", lastSeen: 1).map(\.id) == [3])
    }

    @Test func countsPerPlotUseEachPlotsLastSeen() {
        let log = [change(1, claude), change(2, claude), change(3, plot: "p2", claude), change(4, plot: "p3", cli)]
        let counts = ChangeRules.newCounts(in: log, lastSeen: ["p1": 1, "p2": 3])
        #expect(counts == ["p1": 1])
        #expect(ChangeRules.newCounts(in: log, lastSeen: [:]) == ["p1": 2, "p2": 1])
    }

    @Test func logIsNewestFirstWithYourChanges() {
        let log = [change(1, you), change(2, claude), change(3, plot: "p2", cli), change(4, cli)]
        #expect(ChangeRules.log(in: log, plot: "p1").map(\.id) == [4, 2, 1])
    }

    @Test func logPagesHoldTenNewestFirst() {
        let log = ChangeRules.log(in: (1...23).map { change($0, cli) }, plot: "p1")
        let first = ChangeRules.page(of: log, index: 0)
        #expect(first.changes.map(\.id) == Array((14...23).reversed()))
        #expect(first.index == 0 && first.count == 3)
        #expect(first.range == "1 to 10 of 23")
        #expect(!first.hasNewer && first.hasOlder)

        let last = ChangeRules.page(of: log, index: 2)
        #expect(last.changes.map(\.id) == [3, 2, 1])
        #expect(last.range == "21 to 23 of 23")
        #expect(last.hasNewer && !last.hasOlder)
    }

    @Test func logPageIndexClampsToThePagesThatExist() {
        let log = ChangeRules.log(in: (1...4).map { change($0, cli) }, plot: "p1")
        let page = ChangeRules.page(of: log, index: 5)
        #expect(page.index == 0 && page.count == 1)
        #expect(page.changes.map(\.id) == [4, 3, 2, 1])
        #expect(!page.hasNewer && !page.hasOlder)
        #expect(ChangeRules.page(of: log, index: -1).index == 0)

        let empty = ChangeRules.page(of: [], index: 0)
        #expect(empty.changes.isEmpty && empty.count == 1 && !empty.hasOlder)
    }

    @Test func creationHasNoUndo() {
        let creation = change(1, cli, entries: [
            ChangeEntry(item: "name", field: "value", old: nil, new: "Loam"),
            ChangeEntry(item: "what", field: "value", old: nil, new: ""),
        ])
        #expect(ChangeRules.isCreation(creation))
        #expect(!ChangeRules.canUndo(creation))
        #expect(ChangeRules.canUndo(change(2, claude)))
        // A link add has a new item too, but it is not creation.
        let link = change(3, claude, entries: [ChangeEntry(item: "link:a", field: "label", old: nil, new: "Spec")])
        #expect(ChangeRules.canUndo(link))
    }

    @Test func undoneChangeFindsTheUndoingChange() {
        let log = [change(1, claude), change(2, you, undoOf: 1)]
        #expect(ChangeRules.undoingChange(of: log[0], in: log)?.id == 2)
        #expect(ChangeRules.undoingChange(of: log[1], in: log) == nil)
    }

    @Test func clockFormatsInTheGivenZone() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(ChangeRules.clock("2026-10-02T09:05:00Z", timeZone: utc) == "09:05")
        #expect(ChangeRules.clock("2026-10-02T09:05:00Z", timeZone: tokyo) == "18:05")
        #expect(ChangeRules.clock("not a time", timeZone: utc) == "not a time")
    }

    @Test func linkAddShowsInFullAndTextEditShowsPerWord() {
        let add = change(1, claude, entries: [
            ChangeEntry(item: "link:a", field: "label", old: nil, new: "Spec"),
            ChangeEntry(item: "link:a", field: "position", old: nil, new: "1"),
        ])
        #expect(ChangeRules.entryViews(add) == [.init(title: "Link label", body: .added("Spec"))])
        #expect(ChangeRules.summary(add) == "Added link")
        let edit = change(2, claude, entries: [ChangeEntry(item: "where", field: "value", old: "a b", new: "a c")])
        let view = ChangeRules.entryViews(edit)[0]
        #expect(view.title == "Where it stands")
        #expect(view.body == .words([.init(.same, "a"), .init(.removed, "b"), .init(.added, "c")]))
        #expect(ChangeRules.summary(edit) == "Edited Where it stands")
        let remove = change(3, claude, entries: [ChangeEntry(item: "repo:r", field: "path", old: "/x", new: nil)])
        #expect(ChangeRules.summary(remove) == "Removed repo")
    }
}

@Suite struct AppStateFileTests {
    @Test func keepsKeysItDoesNotKnow() throws {
        let state = tempState()
        try FileManager.default.createDirectory(at: state.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"panes":[{"plot_id":"p1","folder":"/x"}],"other":1}"#.write(to: state.url, atomically: true, encoding: .utf8)
        try state.setLastSeenChanges(["p1": 7])
        #expect(state.lastSeenChanges() == ["p1": 7])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: state.url)) as? [String: Any])
        #expect((object["panes"] as? [[String: String]])?.first?["folder"] == "/x")
        #expect(object["other"] as? Int == 1)
        // A later writer of `panes` keeps `last_seen_changes`.
        try state.setValue([["plot_id": "p2", "folder": "/y"]], forKey: "panes")
        #expect(state.lastSeenChanges() == ["p1": 7])
    }

    @Test func missingFileGivesNil() {
        #expect(tempState().lastSeenChanges() == nil)
    }

    @Test func doesNotOverwriteInvalidJSON() throws {
        let state = tempState()
        try FileManager.default.createDirectory(at: state.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: state.url, atomically: true, encoding: .utf8)
        #expect(throws: AppStateFile.StateError.self) { try state.setLastSeenChanges(["p": 1]) }
        #expect(try String(contentsOf: state.url, encoding: .utf8) == "not json")
    }

    @Test func environmentReplacesTheFolder() {
        let state = AppStateFile(environment: ["LOAM_APP_STATE_DIR": "/tmp/loam-state"])
        #expect(state.url.path == "/tmp/loam-state/state.json")
    }
}

@MainActor
@Suite struct ReviewModelTests {
    /// `changes` fixture: three changes by the app and the CLI. A fake loam prints it for every call.
    private func model(_ outputs: [(fixture: String, exit: Int32)], state: AppStateFile? = nil) throws -> (ReviewModel, FakeLoam, AppStateFile) {
        let fake = try FakeLoam(outputs)
        let state = state ?? tempState()
        return (ReviewModel(client: fake.client(), state: state), fake, state)
    }

    @Test func firstRunBaselinesEveryPlotAsSeen() async throws {
        let (m, _, state) = try model([("changes", 0)])
        await m.reload()
        #expect(!m.changes.isEmpty)
        #expect(m.newCounts.isEmpty)
        #expect(state.lastSeenChanges() != nil)
    }

    @Test func laterReadsAskForChangesAboveTheHighestID() async throws {
        let (m, fake, _) = try model([("changes", 0), ("changes_empty", 0)])
        await m.reload()
        let top = try #require(m.changes.last?.id)
        await m.reload()
        #expect(fake.args() == ["changes --json", "changes --since \(top) --json"])
    }

    @Test func storedLastSeenIsKept() async throws {
        let state = tempState()
        try state.setLastSeenChanges(["plotaaaaab": 0])
        let (m, _, _) = try model([("changes", 0)], state: state)
        await m.reload()
        #expect(m.lastSeen == ["plotaaaaab": 0])
        // The fixture holds app and CLI changes only, so none is new.
        #expect(m.newCount(plot: "plotaaaaab") == 0)
    }

    @Test func markSeenWritesTheNewestIDToTheState() async throws {
        let state = tempState()
        try state.setLastSeenChanges([:])
        let (m, _, _) = try model([("changes", 0)], state: state)
        await m.reload()
        let top = try #require(ChangeRules.newestID(in: m.changes, plot: "plotaaaaab"))
        m.markSeen(plot: "plotaaaaab")
        #expect(m.lastSeen["plotaaaaab"] == top)
        #expect(state.lastSeenChanges()?["plotaaaaab"] == top)
    }

    @Test func undoSendsTheChangeID() async throws {
        let (m, fake, _) = try model([("undo", 0), ("changes", 0)])
        await m.undo(change(41, claude))
        #expect(fake.args().first == "undo 41 --json --actor app")
        #expect(m.clash == nil)
    }

    @Test func aClashShowsThePromptAndOverwriteRunsAgain() async throws {
        let (m, fake, _) = try model([("error_undo_clash", 11), ("undo", 0), ("changes", 0)])
        await m.undo(change(3, claude))
        let prompt = try #require(m.clash)
        #expect(prompt.changeID == 3)
        #expect(prompt.laterChanges.map(\.id) == [4])
        #expect(prompt.undoWouldWrite.first?.item == "what")
        #expect(fake.args().count == 1)
        await m.confirmOverwrite()
        #expect(fake.args()[1] == "undo 3 --overwrite --json --actor app")
        #expect(m.clash == nil)
    }

    @Test func cancelDropsTheClashAndWritesNothing() async throws {
        let (m, fake, _) = try model([("error_undo_clash", 11)])
        await m.undo(change(3, claude))
        m.cancelClash()
        #expect(m.clash == nil)
        #expect(fake.args().count == 1)
    }

    @Test func undoneNoteShowsTheTimeOfTheUndoingChange() async throws {
        let (m, _, _) = try model([("changes", 0)])
        m.timeZone = try #require(TimeZone(identifier: "UTC"))
        await m.reload()
        let target = m.changes[0]
        // No change in the fixture undoes it, so no note.
        #expect(m.undoneNote(target) == nil)
    }

    @Test func sidebarCountsSkipTheActivePlot() async throws {
        let (m, _, _) = try model([("changes", 0)])
        await m.reload()
        #expect(m.sidebarCounts(activePlot: "plotaaaaab").isEmpty)
    }

    @Test func goingToAPaneCallsTheCallback() async throws {
        let (m, _, _) = try model([("changes", 0)])
        let pane = PaneRef(id: PaneID(), name: "claude")
        var went: PaneRef?
        m.onGoToPane = { went = $0 }
        m.goToPane(of: ActorLabel(text: "claude", pane: pane))
        #expect(went == pane)
        went = nil
        m.goToPane(of: ActorLabel(text: "claude"))
        #expect(went == nil)
    }
}

@MainActor
@Suite struct ReviewAppModelTests {
    private func launched(state: AppStateFile) async throws -> AppModel {
        let fake = try FakeLoam([
            ("version", 0), ("setup_check", 0), ("list", 0), ("list_archived", 0), ("changes", 0),
        ])
        let model = AppModel(client: fake.client(), stateFile: state)
        await model.launch(startFeed: false)
        return model
    }

    @Test func closingThePanelMarksTheActivePlotSeen() async throws {
        let state = tempState()
        try state.setLastSeenChanges([:])
        let model = try await launched(state: state)
        let plot = try #require(model.workspace.activePlotID)
        let top = try #require(ChangeRules.newestID(in: model.review.changes, plot: plot))
        model.setPanelVisible(true)
        #expect(model.review.lastSeen[plot] == nil)
        model.setPanelVisible(false)
        #expect(model.review.lastSeen[plot] == top)
        #expect(state.lastSeenChanges()?[plot] == top)
    }

    @Test func switchingPlotWithThePanelOpenMarksTheOldPlotSeen() async throws {
        let state = tempState()
        try state.setLastSeenChanges([:])
        let model = try await launched(state: state)
        let old = try #require(model.workspace.activePlotID)
        let other = try #require(model.plots.first { $0.id != old }?.id)
        let top = try #require(ChangeRules.newestID(in: model.review.changes, plot: old))
        model.activate(plot: other)  // The panel is closed, so nothing is marked.
        #expect(model.review.lastSeen[old] == nil)
        model.activate(plot: old)
        model.setPanelVisible(true)
        model.activate(plot: other)
        #expect(model.review.lastSeen[old] == top)
    }

    @Test func sidebarRowsCarryTheCountsExceptForTheActivePlot() {
        var workspace = Workspace()
        workspace.activate(plot: "p1")
        let plots = [PlotSummary(id: "p1", name: "p1", what: "", createdAt: "2026-10-02T00:00:00Z"), PlotSummary(id: "p2", name: "p2", what: "", createdAt: "2026-10-02T00:00:00Z")]
        let sidebar = SidebarModel(plots: plots, workspace: workspace, collapsed: false, newChangeCounts: ["p1": 3, "p2": 2])
        let rows = sidebar.withPanes + sidebar.noPanes
        #expect(rows.first { $0.id == "p1" }?.newChangeCount == 0)
        #expect(rows.first { $0.id == "p2" }?.newChangeCount == 2)
    }
}

/// The sidebar reads the main repos again only after a change to a repo (ticket 71).
@Suite struct RepoChangeTests {
    @Test func aRepoEntryTouchesTheRepos() {
        let main = ChangeEntry(item: "repo:repoaaaaab", field: "main", old: "false", new: "true")
        #expect(change(1, you, entries: [main]).touchesRepos)
    }

    @Test func otherEntriesDoNotTouchTheRepos() {
        let link = ChangeEntry(item: "link:linkaaaaab", field: "url", old: "a", new: "b")
        #expect(!change(1, you).touchesRepos)
        #expect(!change(2, you, entries: [link]).touchesRepos)
    }
}
