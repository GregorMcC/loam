import Foundation
import Testing

@testable import LoamKit

/// Ticket 208: the Recurring page of a plot lists its recurring runs and adds them, and launchd runs `loam tick`
/// while the app is closed.
@MainActor
@Suite(.waitLimit) struct RecurringTests {
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    @Test func thePageReadsTheRecurringRunsAndTheAgent() async throws {
        let (model, fake) = try model([("recurring_list", 0), ("tick_status", 0)])
        await model.showRecurring(plot: "plotaaaaae")
        #expect(model.page == .recurring("plotaaaaae"))
        #expect(model.recurring.map(\.title) == ["Bump Go dependencies", "Shape new issues"])
        #expect(model.tickStatus?.installed == true)
        #expect(fake.args() == ["recurring list --json -- plotaaaaae", "tick status --json"])
    }

    @Test func aNewRecurringRunGoesToTheCoreWithItsTimetable() async throws {
        let (model, fake) = try model([("recurring_list", 0), ("tick_status", 0), ("recurring_add", 0), ("recurring_list", 0)])
        await model.showRecurring(plot: "plotaaaaae")
        var draft = RecurringDraft()
        draft.title = "Shape new issues"
        draft.prompt = "Shape a run for each new bug."
        draft.days = ["fri", "mon"]
        draft.at = "07:00"
        draft.precheck = "  gh issue list --json number --jq length | grep -qv '^0$' "
        #expect(await model.addRecurring(draft))
        #expect(fake.args().dropFirst(2).first == "recurring add --title Shape new issues --prompt Shape a run for each new bug. "
            + "--kind shape --days fri,mon --at 07:00 --if-asleep once "
            + "--precheck gh issue list --json number --jq length | grep -qv '^0$' --json -- plotaaaaae")
        #expect(fake.args().last == "recurring list --json -- plotaaaaae")
        #expect(model.recurringError == nil)
    }

    @Test func aRecurringRunThatTheCoreRefusesSaysWhy() async throws {
        let (model, _) = try model([("recurring_list", 0), ("tick_status", 0), ("error_invalid", 2)])
        await model.showRecurring(plot: "plotaaaaae")
        #expect(await model.addRecurring(RecurringDraft()) == false)
        #expect(model.recurringError?.isEmpty == false)
    }

    @Test func runNowSaysWhatItDidAndReadsTheRunsAgain() async throws {
        let (model, fake) = try model([("recurring_list", 0), ("tick_status", 0), ("recurring_run", 0), ("run_list", 0),
                                       ("recurring_list", 0)])
        var toasts: [String] = []
        model.onToast = { text, _ in toasts.append(text) }
        await model.showRecurring(plot: "plotaaaaae")
        let id = try #require(model.recurring.last?.id)
        await model.runRecurringNow(id)
        #expect(fake.args()[2] == "recurring run --json -- \(id)")
        #expect(fake.args()[3] == "run list --json")
        #expect(toasts == ["Shape new issues: Claude drafted a run for your approval"])
    }

    @Test func removeAndTheAgentGoToTheCore() async throws {
        let (model, fake) = try model([("recurring_list", 0), ("tick_status", 0), ("recurring_rm", 0), ("recurring_list", 0),
                                       ("tick_uninstall", 0)])
        await model.showRecurring(plot: "plotaaaaae")
        let id = try #require(model.recurring.last?.id)
        await model.removeRecurring(id)
        await model.setTickAgent(installed: false)
        #expect(Array(fake.args().dropFirst(2)) == ["recurring rm --json -- \(id)", "recurring list --json -- plotaaaaae",
                                                    "tick uninstall --json"])
        #expect(model.tickStatus?.installed == false)
    }

    /// With no launchd agent, the app ticks the recurring runs itself while it is open.
    @Test func theAppTicksTheRecurringRunsWhenNoAgentDoes() async throws {
        let (model, fake) = try model([("recurring_list", 0), ("tick_uninstall", 0), ("tick", 0), ("run_list", 0),
                                       ("recurring_list", 0)])
        await model.showRecurring(plot: "plotaaaaae")
        #expect(model.appTicksRecurring)
        // The tick skipped a run, so the runs and the page read again.
        await model.tickRecurring()
        #expect(Array(fake.args().suffix(3)) == ["tick --json", "run list --json", "recurring list --json -- plotaaaaae"])
    }
}

@Suite struct RecurringWordsTests {
    @Test func theTimetableNamesADaySetOrTheDays() {
        #expect(RecurringWords.timetable(days: ["mon", "tue", "wed", "thu", "fri"], at: "06:30") == "Weekdays 06:30")
        #expect(RecurringWords.timetable(days: ["sat", "sun"], at: "10:00") == "Weekends 10:00")
        #expect(RecurringWords.timetable(days: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"], at: "02:00") == "Every day 02:00")
        #expect(RecurringWords.timetable(days: ["wed", "mon"], at: "07:00") == "Mon, Wed 07:00")
    }

    @Test func aTimeIsADayOfTheWeekNearNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T09:00:00Z"))
        #expect(RecurringWords.when("2026-10-28T09:00:00Z", now: now, calendar: calendar).hasPrefix("today "))
        #expect(RecurringWords.when("2026-10-29T06:30:00Z", now: now, calendar: calendar).hasPrefix("tomorrow "))
        // The core writes a time with milliseconds when it has them.
        #expect(RecurringWords.when("2026-10-28T08:59:33.692Z", now: now, calendar: calendar).hasPrefix("today "))
        #expect(RecurringWords.when("not a time", now: now, calendar: calendar) == "not a time")
    }

    @Test func aRunOfARecurringRunNamesNoID() {
        #expect(RunSource(kind: "recurring", key: "fpdgh74ncr", url: "").label == "Recurring")
        #expect(RunSource(kind: "github", key: "#57", url: "").label == "#57")
    }
}
