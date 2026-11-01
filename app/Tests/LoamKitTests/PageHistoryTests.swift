import Foundation
import Testing
@testable import LoamKit

/// TAS-46: Back and Forward between pages, as a browser does.
@Suite struct PageHistoryTests {
    typealias Place = PageHistory.Place

    private let today = Place.page(.today)
    private let intake = Place.page(.intake("p1"))
    private let run = Place.page(.run("r1"))
    private let plot = Place.space(.plot("p1"))
    private let nothingGone: (Place) -> Bool = { _ in false }

    private func history(_ places: [Place]) -> PageHistory {
        var history = PageHistory()
        for place in places { history.visit(place) }
        return history
    }

    @Test func anEmptyHistoryGoesNowhere() {
        var history = PageHistory()
        #expect(history.current == nil)
        #expect(history.back(isGone: nothingGone) == nil)
        #expect(history.forward(isGone: nothingGone) == nil)
        #expect(!history.canGoBack(isGone: nothingGone))
        #expect(!history.canGoForward(isGone: nothingGone))
    }

    @Test func backAndForwardWalkThePlaces() {
        var history = history([plot, today, intake, run])
        #expect(history.current == run)
        #expect(history.back(isGone: nothingGone) == intake)
        #expect(history.back(isGone: nothingGone) == today)
        #expect(history.back(isGone: nothingGone) == plot)
        // The first place has nothing before it: Back does nothing.
        #expect(history.back(isGone: nothingGone) == nil)
        #expect(history.current == plot)
        #expect(history.forward(isGone: nothingGone) == today)
        #expect(history.forward(isGone: nothingGone) == intake)
        #expect(history.forward(isGone: nothingGone) == run)
        #expect(history.forward(isGone: nothingGone) == nil)
        #expect(history.current == run)
    }

    @Test func aNewVisitClearsTheForwardPlaces() {
        var history = history([today, intake, run])
        _ = history.back(isGone: nothingGone)
        _ = history.back(isGone: nothingGone)
        history.visit(plot)
        #expect(history.places == [today, plot])
        #expect(!history.canGoForward(isGone: nothingGone))
        #expect(history.back(isGone: nothingGone) == today)
    }

    @Test func aVisitToTheCurrentPlaceAddsNoStep() {
        var history = history([today, run, run])
        #expect(history.places == [today, run])
        // A Back, then a visit to the place that Back showed, keeps the forward places.
        _ = history.back(isGone: nothingGone)
        history.visit(today)
        #expect(history.places == [today, run])
        #expect(history.forward(isGone: nothingGone) == run)
    }

    /// A move of the desk to another run is no step, and the desk place keeps the last run.
    @Test func theDeskKeepsItsLastRun() {
        var history = history([today, .page(.desk, deskRun: "r1"), .page(.desk, deskRun: "r2")])
        #expect(history.places == [today, .page(.desk, deskRun: "r2")])
        history.visit(run)
        #expect(history.back(isGone: nothingGone) == .page(.desk, deskRun: "r2"))
    }

    @Test func aPlaceThatIsGoneIsSkipped() {
        let archived = Place.space(.plot("p2"))
        var history = history([today, archived, run, intake])
        let gone: (Place) -> Bool = { $0 == archived || $0 == run }
        #expect(history.back(isGone: gone) == today)
        #expect(history.forward(isGone: gone) == intake)
        // Only gone places before: Back does nothing, and the history stays where it is.
        var stuck = self.history([run, archived, intake])
        #expect(!stuck.canGoBack(isGone: gone))
        #expect(stuck.back(isGone: gone) == nil)
        #expect(stuck.current == intake)
    }

    @Test func theHistoryKeepsTheNewestPlaces() {
        var history = PageHistory()
        for n in 0..<(PageHistory.limit + 5) { history.visit(.page(.run("r\(n)"))) }
        #expect(history.places.count == PageHistory.limit)
        #expect(history.places.first == .page(.run("r5")))
        #expect(history.current == .page(.run("r\(PageHistory.limit + 4)")))
    }
}

/// TAS-46: the model records a step for each move to a page, a plot or Home, and Back and Forward show each place again.
@MainActor
@Suite(.waitLimit, .temporaryFolders) struct PageHistoryModelTests {
    /// Two plots and three runs: r1 and r2 wait at the desk, r1 first, and r3 runs. Every call to the core fails, so
    /// the pages keep what the test gives them.
    func model() throws -> AppModel {
        let fake = try FakeLoam([("", 1)])
        let model = AppModel(client: fake.client())
        model.apply(Array(TodayContentTests.plots.prefix(2)))
        model.runs = [
            TodayContentTests.run("r3", plot: "p1", .running),
            TodayContentTests.run("r2", plot: "p1", .ready),
            TodayContentTests.run("r1", plot: "p2", .ready),
        ]
        return model
    }

    @Test func backAndForwardWalkThePagesAndThePlots() async throws {
        let model = try model()
        #expect(model.deskQueue.map(\.id) == ["r1", "r2"])
        #expect(!model.canGoBack)
        model.showToday()
        await model.showIntake(plot: "p1")
        await model.openDesk("r1")
        // The desk's own next run is no step: the desk place keeps the run it shows.
        await model.moveDesk(by: 1)
        await model.openRun("r3")
        await model.showRecurring(plot: "p2")
        #expect(model.history.places == [
            .space(.plot("p1")), .page(.today), .page(.intake("p1")), .page(.desk, deskRun: "r2"), .page(.run("r3")),
            .page(.recurring("p2")),
        ])

        await model.goBack()
        #expect(model.page == .run("r3"))
        await model.goBack()
        #expect(model.page == .desk && model.desk.runID == "r2")
        await model.goBack()
        #expect(model.page == .intake("p1"))
        await model.goBack()
        #expect(model.page == .today)
        await model.goBack()
        #expect(model.page == nil && model.workspace.activeSpace == .plot("p1"))
        // Nothing before the first place: Back does nothing.
        #expect(!model.canGoBack)
        await model.goBack()
        #expect(model.page == nil && model.workspace.activeSpace == .plot("p1"))
        // A Back adds no step.
        #expect(model.history.places.count == 6)

        await model.goForward()
        #expect(model.page == .today)
        await model.goForward()
        await model.goForward()
        #expect(model.page == .desk && model.desk.runID == "r2")
        await model.goForward()
        await model.goForward()
        #expect(model.page == .recurring("p2"))
        #expect(!model.canGoForward)

        // A new move clears the forward places.
        await model.goBack()
        await model.goBack()
        model.activate(plot: "p2")
        #expect(model.history.places.suffix(2) == [.page(.desk, deskRun: "r2"), .space(.plot("p2"))])
        #expect(!model.canGoForward)
        await model.goBack()
        #expect(model.page == .desk && model.desk.runID == "r2")
    }

    /// A plot is one step, with no page and no record of the focused tab. A move between tabs is no step, and a move
    /// to the place that shows is no new step.
    @Test func onlyMovesBetweenPagesPlotsAndHomeAreSteps() async throws {
        let model = try model()
        model.activate(plot: "p1")
        model.openTab(.shell)
        model.openTab(.shell)
        model.selectTab(number: 1)
        model.activateHome()
        model.activateHome()
        model.showToday()
        model.showToday()
        #expect(model.history.places == [.space(.plot("p1")), .space(.home), .page(.today)])
        // A move from a page to a pane of the active space is a step to the space.
        let pane = try #require(model.workspace.tabs(of: "p1").first?.focused)
        model.goToPane(pane)
        #expect(model.history.places.last == .space(.plot("p1")))
        await model.goBack()
        #expect(model.page == .today)
        await model.goBack()
        #expect(model.page == nil && model.workspace.activeSpace == .home)
    }

    /// A run that left the list and an archived plot are skipped. A landed run keeps its page. A desk run that left the
    /// queue gives way to the first run of the queue.
    @Test func placesThatAreGoneAreSkipped() async throws {
        let model = try model()
        await model.openRun("r3")
        model.activate(plot: "p2")
        await model.openDesk("r1")
        await model.openRun("r2")
        model.showToday()

        // r3 leaves the list, r1 and r2 land, and p2 is archived.
        model.runs = [
            TodayContentTests.run("r2", plot: "p1", .landed),
            TodayContentTests.run("r1", plot: "p2", .landed),
            TodayContentTests.run("r4", plot: "p1", .ready),
        ]
        model.apply([TodayContentTests.plots[0]], archived: [TodayContentTests.plots[1]])

        await model.goBack()
        #expect(model.page == .run("r2"))
        await model.goBack()
        #expect(model.page == .desk && model.desk.runID == "r4")
        await model.goBack()
        #expect(model.page == nil && model.workspace.activeSpace == .plot("p1"))
        #expect(!model.canGoBack)
        await model.goForward()
        #expect(model.page == .desk)
    }

    /// The run page Back control goes one step back, and with no place before, to Today.
    @Test func theRunPageBackGoesOneStepBackElseToToday() async throws {
        let model = try model()
        await model.showIntake(plot: "p1")
        await model.openRun("r3")
        await model.runPageBack()
        #expect(model.page == .intake("p1"))

        let fresh = AppModel(client: try FakeLoam([("", 1)]).client())
        fresh.runs = model.runs
        await fresh.openRun("r3")
        #expect(!fresh.canGoBack)
        await fresh.runPageBack()
        #expect(fresh.page == .today)
    }
}
