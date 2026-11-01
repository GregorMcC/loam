import Foundation
import Testing

@testable import LoamKit

/// Settings > Runs and the Linear parts of Settings > Connections: the words and the rows that the views show.
@MainActor
@Suite(.waitLimit, .temporaryFolders) struct SettingsRunsTests {
    private func plot(_ name: String, archived: Bool = false, links: [(String, String)]) -> Plot {
        let items = links.enumerated().map { index, link in
            PlotLink(id: "l\(index)", label: link.0, target: link.1, note: "", position: index, version: 1,
                     kind: .linear, exists: nil)
        }
        return Plot(id: name, name: name, what: "", why: "", whereItStands: "", createdAt: "", archived: archived,
                    links: items, repos: [], versions: [:], revision: 1)
    }

    @Test func aTeamLinkAndAProjectLinkGiveTheirScopes() {
        let rows = PlotScopeRow.rows(plots: [
            plot("Redesign", links: [("ENG", "https://linear.app/acme/team/eng/active"),
                                     ("Loam project in Linear", "https://linear.app/acme/project/loam-redesign-8f3a2b1c9d0e/overview")]),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].scope == "ENG team \u{B7} Loam redesign project")
        #expect(rows[0].source == "ENG, Loam project in Linear")
        #expect(rows[0].hasScope)
    }

    @Test func aPlotWithNoLinearScopeSaysNone() {
        let rows = PlotScopeRow.rows(plots: [
            plot("A", links: []),
            plot("B", links: [("An issue", "https://linear.app/acme/issue/ENG-5/title"), ("Docs", "https://example.com")]),
        ])
        #expect(rows.map(\.scope) == ["None", "None"])
        #expect(rows.map(\.source) == ["No Linear link", "No Linear link"])
        #expect(!rows[0].hasScope)
    }

    @Test func anArchivedPlotHasNoRow() {
        let rows = PlotScopeRow.rows(plots: [plot("Old", archived: true, links: []), plot("New", links: [])])
        #expect(rows.map(\.plot) == ["New"])
    }

    @Test func theKeyMaskHasNoRealCharacters() {
        #expect(ConnectionsModel.keyMask == "lin_api_\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
    }

    @Test func connectionsLoadsTheSwitchesAndTheAccount() async throws {
        let fake = try FakeLoam([("linear_status", 0), ("linear_updates", 0), ("list", 0), ("show", 0)])
        let model = ConnectionsModel(client: fake.client())
        await model.load()
        #expect(model.accountWords == "Ada Example \u{B7} workspace Acme")
        #expect(model.updates?.walkthroughComment == false && model.updates?.done == true)
        #expect(fake.args().prefix(3) == ["linear status --json", "linear updates --json", "list --json"])
    }

    @Test func aSwitchPassesOnlyItsOwnFlag() async throws {
        let fake = try FakeLoam([("linear_status", 0), ("linear_updates", 0), ("list", 0), ("show", 0), ("linear_updates_set", 0)])
        let model = ConnectionsModel(client: fake.client())
        await model.load()
        let before = fake.args().count
        await model.setUpdate(\.walkthroughComment, true)
        #expect(Array(fake.args().dropFirst(before)) == ["linear updates --walkthrough on --json"])
    }

    @Test func runsReadsLimitsAndSavesOneLimit() async throws {
        let fake = try FakeLoam([("run_limits_get", 0), ("usage_refresh", 0), ("run_limits_set", 0)])
        let model = RunsSettingsModel(client: fake.client(), now: { Date(timeIntervalSince1970: 1_767_225_600 + 60) })
        await model.load()
        #expect(model.limits == RunLimits(atATime: 3, maxTurns: 40, holdAt: 80))
        // A reading one minute old is not read again.
        #expect(fake.args() == ["run limits --json", "usage --json"])
        await model.setAtATime(50)
        #expect(fake.args().last == "run limits --at-a-time 20 --max-turns 40 --hold-at 80 --json")
    }

    @Test func aStaleReadingIsReadAgainOnce() async throws {
        let fake = try FakeLoam([("run_limits_get", 0), ("usage_refresh", 0)])
        let model = RunsSettingsModel(client: fake.client(), now: { Date(timeIntervalSince1970: 1_767_225_600 + 3600) })
        await model.load()
        #expect(fake.args() == ["run limits --json", "usage --json", "usage --refresh --json"])
    }

    @Test func staleness() {
        let now = Date(timeIntervalSince1970: 1_767_225_600 + 1800)
        #expect(RunsSettingsModel.isStale(nil, now: now))
        let fresh = Usage(fiveHour: nil, sevenDay: nil, readAt: "2026-01-01T00:00:00Z")
        #expect(!RunsSettingsModel.isStale(fresh, now: now))
        #expect(RunsSettingsModel.isStale(fresh, now: now.addingTimeInterval(1)))
        #expect(RunsSettingsModel.isStale(Usage(fiveHour: nil, sevenDay: nil, readAt: nil), now: now))
    }

    @Test func usageWordsNameThePercentAndTheReset() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let week = UsageWindow(utilization: 0.41, resetsAt: "2026-01-03T09:00:00Z")
        let usage = Usage(fiveHour: nil, sevenDay: week, readAt: "2026-01-01T00:00:00Z")
        #expect(RunsSettingsModel.usageWords(usage, now: now, calendar: calendar) == "41% used, resets Sat 09:00")
        #expect(RunsSettingsModel.usageWords(Usage(fiveHour: nil, sevenDay: nil, readAt: nil), now: now) == nil)
    }
}
