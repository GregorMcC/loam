import Testing

@testable import LoamKit

/// Ticket 123: Tab and Shift-Tab in a sheet or a popover move the keys through its text fields, in the order that it draws
/// them, and never out of it.
@Suite struct TabStopsTests {
    enum Stop { case card, branch, goal, url }

    @Test func tabMovesDownAndShiftTabMovesUp() {
        let stops: [Stop] = [.branch, .goal, .url]
        #expect(TabStops.next(after: .branch, in: stops, back: false) == .goal)
        #expect(TabStops.next(after: .goal, in: stops, back: false) == .url)
        #expect(TabStops.next(after: .url, in: stops, back: true) == .goal)
        #expect(TabStops.next(after: .goal, in: stops, back: true) == .branch)
    }

    @Test func theKeysGoRound() {
        let stops: [Stop] = [.branch, .goal, .url]
        #expect(TabStops.next(after: .url, in: stops, back: false) == .branch, "Tab from the last field goes to the first")
        #expect(TabStops.next(after: .branch, in: stops, back: true) == .url, "Shift-Tab from the first field goes to the last")
    }

    @Test func fromTheCardTabGoesToTheFirstFieldAndShiftTabToTheLast() {
        let stops: [Stop] = [.branch, .goal]
        #expect(TabStops.next(after: .card, in: stops, back: false) == .branch)
        #expect(TabStops.next(after: .card, in: stops, back: true) == .goal)
        // A field that is gone, such as the URL field after you choose another link, is no stop either.
        #expect(TabStops.next(after: .url, in: stops, back: false) == .branch)
    }

    @Test func oneFieldKeepsTheKeys() {
        #expect(TabStops.next(after: .goal, in: [Stop.goal], back: false) == .goal)
        #expect(TabStops.next(after: .goal, in: [Stop.goal], back: true) == .goal)
        #expect(TabStops.next(after: .card, in: [Stop.goal], back: true) == .goal)
    }

    @Test func noFieldIsNoStop() {
        #expect(TabStops.next(after: .card, in: [Stop](), back: false) == nil)
        #expect(TabStops.next(after: .branch, in: [Stop](), back: true) == nil)
    }
}
