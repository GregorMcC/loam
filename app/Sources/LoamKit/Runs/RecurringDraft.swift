import Foundation

/// What `loam recurring add` needs (ticket 208).
public struct RecurringDraft: Equatable, Sendable {
    public var title = ""
    public var prompt = ""
    public var kind = Recurring.Kind.shape
    /// The days of the week: sun, mon, and so on.
    public var days = ["mon", "tue", "wed", "thu", "fri"]
    /// HH:MM.
    public var at = "07:00"
    public var precheck = ""
    public var ifAsleep = Recurring.IfAsleep.once
    /// True when you saw the setup command of the repo, for a chore.
    public var approveSetup = false

    public init() {}
}
