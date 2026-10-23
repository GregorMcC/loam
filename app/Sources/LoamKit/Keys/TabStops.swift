import Foundation

/// Tab and Shift-Tab in a sheet or a popover over the window (ticket 123). The key view loop of AppKit does not fit these
/// overlays: Tab from a field goes to the focus proxy of the card and back, so a field further down never gets the keys,
/// and Shift-Tab leaves the overlay for the window under it. So with keyboard navigation off, the macOS default, the
/// overlay moves the keys itself. The stops are its text fields, in the order that it draws them.
public enum TabStops {
    /// The stop that Tab moves the keys to from `current`, or Shift-Tab with `back`. The keys go round: Tab from the last
    /// stop goes to the first. From a view that is no stop, such as the card or a field that is gone, Tab goes to the
    /// first stop and Shift-Tab to the last. Nil when there is no stop.
    public static func next<Stop: Equatable>(after current: Stop, in stops: [Stop], back: Bool) -> Stop? {
        guard let index = stops.firstIndex(of: current) else { return back ? stops.last : stops.first }
        return stops[(index + (back ? stops.count - 1 : 1)) % stops.count]
    }
}
