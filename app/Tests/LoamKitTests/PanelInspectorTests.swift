import Foundation
import Testing
@testable import LoamKit

private func change(_ actor: Actor, entries: [ChangeEntry], undoOf: Int? = nil) -> Change {
    Change(id: 1, plotID: "p", at: "2026-10-02T09:05:00Z", actor: actor, entries: entries, undoOf: undoOf)
}

private let you = Actor(kind: .app, sessionID: nil, loamStarted: nil)
private let cli = Actor(kind: .cli, sessionID: nil, loamStarted: nil)
private let seeded = Actor(kind: .session, sessionID: "abc", loamStarted: true)
private let outside = Actor(kind: .session, sessionID: "abc", loamStarted: false)
private let text = [ChangeEntry(item: "where", field: "value", old: "a", new: "b")]
private let linkAdd = [ChangeEntry(item: "link:x", field: "label", old: nil, new: "Roadmap")]

@Suite struct PanelInspectorTests {
    @Test func linkKindLabels() {
        func label(_ kind: LinkKind) -> String {
            PlotLink(id: "l", label: "x", target: "t", note: "", position: 0, version: 1, kind: kind, exists: nil).kindLabel
        }
        #expect(label(.path) == "Local")
        #expect(label(.vault) == "Vault")
        #expect(label(.github) == "GitHub")
        #expect(label(.url) == "Web")
        #expect(label(.notion) == "Notion")
        #expect(label(.linear) == "Linear")
    }

    @Test func paneSummary() {
        #expect(PanelProperties.paneSummary(panes: 0, needsYou: 0, doneUnread: 0) == "No panes")
        #expect(PanelProperties.paneSummary(panes: 1, needsYou: 0, doneUnread: 0) == "1 pane")
        #expect(PanelProperties.paneSummary(panes: 3, needsYou: 0, doneUnread: 1) == "3 panes \u{00B7} 1 Done, unread")
        #expect(PanelProperties.paneSummary(panes: 3, needsYou: 2, doneUnread: 0) == "3 panes \u{00B7} 2 Need you")
        #expect(PanelProperties.paneSummary(panes: 2, needsYou: 1, doneUnread: 1)
            == "2 panes \u{00B7} 1 Needs you, 1 Done, unread")
    }

    @Test func actorNameAndGlyph() {
        #expect(ChangeRules.actorName(seeded) == "Claude")
        #expect(ChangeRules.actorName(outside) == "Claude")
        #expect(ChangeRules.actorName(you) == "You")
        #expect(ChangeRules.actorName(cli) == "You")
        #expect(ChangeRules.actorGlyph(seeded) == .claude)
        #expect(ChangeRules.actorGlyph(you) == .person)
        #expect(ChangeRules.actorGlyph(cli) == .terminal)
    }

    @Test func sentenceAfterTheActor() {
        #expect(ChangeRules.sentence(change(seeded, entries: text)) == "set Where it stands")
        #expect(ChangeRules.sentence(change(you, entries: linkAdd)) == "added link")
        #expect(ChangeRules.sentence(change(you, entries: [], undoOf: 4)) == "undid change 4")
        let two = [ChangeEntry(item: "what", field: "value", old: "a", new: "b"),
                   ChangeEntry(item: "why", field: "value", old: "a", new: "b")]
        #expect(ChangeRules.sentence(change(you, entries: two)) == "set What, Why")
    }

    @Test func sourceOfAChange() {
        #expect(ChangeRules.source(seeded, paneName: nil) == "seeded session")
        #expect(ChangeRules.source(seeded, paneName: "claude \u{00B7} app") == "claude \u{00B7} app")
        #expect(ChangeRules.source(outside, paneName: nil) == "another Claude session")
        #expect(ChangeRules.source(cli, paneName: nil) == "CLI")
        #expect(ChangeRules.source(you, paneName: nil) == "app")
    }

    @Test func stampShowsTheDayOnlyForAnotherDay() {
        let utc = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-02T18:00:00Z")!
        #expect(ChangeRules.stamp("2026-10-02T09:05:00Z", now: now, timeZone: utc) == "09:05")
        #expect(ChangeRules.stamp("2026-09-30T09:05:00Z", now: now, timeZone: utc) == "30 Sep, 09:05")
    }
}
