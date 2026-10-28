import Foundation

/// Back and Forward between pages, as a browser does (TAS-46). The history holds the places that you visited, in
/// memory only. Back goes to the place before the one it shows, and Forward to the place after. A visit to a new place
/// clears the places after the one it shows. A place that is gone, such as a run that left the list, is skipped.
public struct PageHistory: Equatable, Sendable {
    /// A step of the history: a page, or a plot or Home with no page.
    public enum Place: Equatable, Sendable {
        /// A page. For the desk, `deskRun` is the run that the desk shows. A move of the desk to another run is not a
        /// step, so the place keeps the last run that the desk showed.
        case page(AppPage, deskRun: String? = nil)
        /// A plot or Home with no page. The history does not keep the tab or the pane that had the focus.
        case space(Space)

        /// True for the same page or space. Two places at the desk are the same place, with different runs.
        func isSame(as other: Place) -> Bool {
            switch (self, other) {
            case (.page(let a, _), .page(let b, _)): a == b
            case (.space(let a), .space(let b)): a == b
            default: false
            }
        }
    }

    /// The most places that the history keeps. A visit past it drops the oldest place.
    public static let limit = 100

    public private(set) var places: [Place] = []
    /// The index in `places` of the place that the window shows, or nil when the history is empty.
    public private(set) var index: Int?

    public init() {}

    /// The place that the window shows, as the history knows it.
    public var current: Place? { index.map { places[$0] } }

    /// Records a visit. A visit to the place that the history shows changes no step: at the desk, it keeps the new run.
    /// A visit to another place clears the places after the current one, then adds the new one.
    public mutating func visit(_ place: Place) {
        if let index, places[index].isSame(as: place) {
            places[index] = place
            return
        }
        let kept = index.map { places.prefix($0 + 1) } ?? []
        places = Array(kept.suffix(Self.limit - 1)) + [place]
        index = places.count - 1
    }

    /// Moves back to the nearest place before the current one that is not gone, and returns it. Nil, and no move, when
    /// there is none.
    public mutating func back(isGone: (Place) -> Bool) -> Place? {
        guard let target = backIndex(isGone: isGone) else { return nil }
        index = target
        return places[target]
    }

    /// Moves forward to the nearest place after the current one that is not gone, and returns it. Nil, and no move, when
    /// there is none.
    public mutating func forward(isGone: (Place) -> Bool) -> Place? {
        guard let target = forwardIndex(isGone: isGone) else { return nil }
        index = target
        return places[target]
    }

    public func canGoBack(isGone: (Place) -> Bool) -> Bool { backIndex(isGone: isGone) != nil }

    public func canGoForward(isGone: (Place) -> Bool) -> Bool { forwardIndex(isGone: isGone) != nil }

    private func backIndex(isGone: (Place) -> Bool) -> Int? {
        guard let index else { return nil }
        return places.indices.prefix(index).last { !isGone(places[$0]) }
    }

    private func forwardIndex(isGone: (Place) -> Bool) -> Int? {
        guard let index else { return nil }
        return places.indices.suffix(from: index + 1).first { !isGone(places[$0]) }
    }
}
