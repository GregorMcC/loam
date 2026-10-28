import Foundation

/// Back and Forward between pages (TAS-46). Each move to a page, a plot or Home is a step: the history records it when
/// the page or the active space changes, so every way there counts. A move between panes or tabs is not a step.
extension AppModel {
    /// The place that the window shows: the page, else the active space.
    var shownPlace: PageHistory.Place? {
        switch page {
        case .desk: .page(.desk, deskRun: desk.runID)
        case let page?: .page(page)
        case nil: workspace.activeSpace.map { .space($0) }
        }
    }

    /// Records the place that the window shows as a step. A place that the history shows already is no new step.
    func recordPlace() {
        guard !holdsPlace, let place = shownPlace else { return }
        history.visit(place)
    }

    /// Runs `body` as one step: the history records only the place where it ends.
    func asOneStep(_ body: () -> Void) {
        let held = holdsPlace
        holdsPlace = true
        body()
        holdsPlace = held
        recordPlace()
    }

    /// True for a place that you cannot go back to: a run that is not in the list, or a plot that is archived or deleted.
    func isGone(_ place: PageHistory.Place) -> Bool {
        switch place {
        case .page(.today, _), .page(.desk, _), .space(.home):
            false
        case .page(.run(let id), _):
            !runs.contains { $0.id == id }
        case .page(.intake(let plot), _), .page(.recurring(let plot), _), .space(.plot(let plot)):
            !plots.contains { $0.id == plot }
        }
    }

    public var canGoBack: Bool { history.canGoBack(isGone: isGone) }

    public var canGoForward: Bool { history.canGoForward(isGone: isGone) }

    /// Back: shows the place before, and reads its data again. With no place before, it does nothing.
    public func goBack() async {
        guard let place = history.back(isGone: isGone) else { return }
        await show(place)
    }

    /// Forward: shows the place after, and reads its data again. With no place after, it does nothing.
    public func goForward() async {
        guard let place = history.forward(isGone: isGone) else { return }
        await show(place)
    }

    /// The run page Back control: one step back, else Today, as before the history.
    public func runPageBack() async {
        if canGoBack {
            await goBack()
        } else {
            showToday()
        }
    }

    /// Shows a place of the history through its open function, so its data loads. The history moved to the place
    /// already, so the open records no new step. A desk run that left the queue gives way to the first run of it.
    private func show(_ place: PageHistory.Place) async {
        switch place {
        case .page(.today, _): showToday()
        case .page(.desk, let run): await openDesk(deskQueue.contains { $0.id == run } ? run : nil)
        case .page(.run(let id), _): await openRun(id)
        case .page(.intake(let plot), _): await showIntake(plot: plot)
        case .page(.recurring(let plot), _): await showRecurring(plot: plot)
        case .space(let space): show(space)
        }
    }
}
