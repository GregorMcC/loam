import Foundation

/// What the action bar shows on Today and on the Intake page: the page and what it shows at the left, and the keys of
/// the page at the right, before Actions. The other pages keep the bar of the panes.
public struct PageBar: Equatable, Sendable {
    /// One key of the page.
    public struct Item: Equatable, Sendable {
        /// What a click does. Nil for a key that the page handles, which the bar only names.
        public enum Action: Equatable, Sendable { case openDesk, startRun }
        public var title: String
        public var keys: [String]
        public var action: Action?
    }

    public var title: String
    public var detail: String
    public var items: [Item]

    /// The bar of the page, or nil for a page that keeps the bar of the panes. `plotName` names the plot of the Intake
    /// page.
    public init?(page: AppPage?, plotName: String) {
        switch page {
        case .today:
            self.init(title: "Today", detail: "All plots", items: [
                Item(title: "Open the desk", keys: ["\u{2318}", "\u{21A9}"], action: .openDesk),
                Item(title: "Start a run", keys: ["\u{2318}", "R"], action: .startRun),
            ])
        case .intake:
            self.init(title: "Intake", detail: plotName, items: [
                Item(title: "Select", keys: ["X"], action: nil),
                Item(title: "Shape selected", keys: ["\u{2318}", "\u{21A9}"], action: nil),
            ])
        default:
            return nil
        }
    }

    public init(title: String, detail: String, items: [Item]) {
        self.title = title
        self.detail = detail
        self.items = items
    }
}
