import Foundation
import Testing

@testable import LoamKit

/// Ticket 204: the Intake page lists the open issues and map tickets of a plot, and starts a run from one.
@MainActor
@Suite(.waitLimit) struct IntakeTests {
    /// The intake fixture is for the plot plotaaaaae, as the run fixtures are.
    func model(_ fixtures: [(String, Int32)]) throws -> (AppModel, FakeLoam) {
        let fake = try FakeLoam(fixtures)
        let model = AppModel(client: fake.client())
        model.apply([PlotSummary(id: "plotaaaaae", name: "Runs", what: "", createdAt: "2026-01-01T00:00:00Z")])
        return (model, fake)
    }

    static func item(_ source: String, url: String) -> IntakeItem {
        IntakeItem(source: source, key: "k", title: "Fix the login form", status: "Open", priority: "", labels: [], url: url,
                   updatedAt: "", runID: "")
    }

    @Test func aDraftStartsFromTheIssueOrTheTicketOfItsItem() {
        let issue = RunDraft(item: Self.item("github", url: "https://github.com/example/widgets/issues/57"))
        #expect(issue.title == "Fix the login form")
        #expect(issue.link == "https://github.com/example/widgets/issues/57" && issue.ticket == nil)
        let ticket = RunDraft(item: Self.item("map", url: "/maps/build/issues/12-plan.md"))
        #expect(ticket.ticket == "/maps/build/issues/12-plan.md" && ticket.link == nil)
        #expect(ticket.maxTries == 3 && ticket.checks.isEmpty && !ticket.approveSetup)
    }

    @Test func intakeReadsTheListOfThePlot() async throws {
        let (model, fake) = try model([("intake_list", 0)])
        await model.showIntake(plot: "plotaaaaae")
        #expect(model.page == .intake("plotaaaaae"))
        #expect(model.intake?.items.map(\.key) == ["ENG-523", "ENG-525", "#61", "#57", "map 12", "map 13"])
        #expect(model.intake?.items[0].priority == "High")
        #expect(model.intake?.items[3].runID == "runraaaaab")
        #expect(fake.args() == ["intake list --json -- plotaaaaae"])
        // A move to a plot closes the page.
        model.activate(plot: "plotaaaaae")
        #expect(model.page == nil)
    }

    @Test func aStartedRunOpensItsPage() async throws {
        let (model, fake) = try model([("intake_list", 0), ("run_start", 0), ("run_list", 0), ("run_status", 0)])
        await model.showIntake(plot: "plotaaaaae")
        var draft = RunDraft(item: try #require(model.intake?.items[4]))
        draft.goal = "Show the plan."
        draft.checks = [RunCheck(name: "Tests", command: "go test ./...")]
        draft.approveSetup = true
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft))
        #expect(model.page == .run("runraaaaab"))
        #expect(model.runStartError == nil)
        let start = try #require(fake.args().dropFirst().first)
        #expect(start == "run start --title Run page: show the plan --goal Show the plan. --check Tests=go test ./... "
            + "--max-tries 3 --ticket /tmp/loam-contract/build/issues/12-run-page-plan.md --approve-setup --json -- plotaaaaae")
        #expect(Array(fake.args().suffix(2)) == ["run list --json", "run status --json -- runraaaaab"])
    }

    @Test func aRunThatDoesNotStartKeepsThePageAndSaysWhy() async throws {
        let (model, _) = try model([("intake_list", 0), ("error_invalid", 2)])
        await model.showIntake(plot: "plotaaaaae")
        let draft = RunDraft(item: try #require(model.intake?.items[0]))
        #expect(await model.startRun(plot: "plotaaaaae", draft: draft) == false)
        #expect(model.page == .intake("plotaaaaae"))
        #expect(model.runStartError?.isEmpty == false)
    }
}
