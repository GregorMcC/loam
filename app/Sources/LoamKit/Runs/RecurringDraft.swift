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
    /// The hash for `--approve-setup`, for a chore: `setupHash` of the setup command that you saw. Nil approves nothing.
    public var approveSetup: String?
    /// The model for `--model`, or "" for the plot default.
    public var model = ""
    /// The level for `--effort`, or "" for the plot default.
    public var effort = ""

    public init() {}
}
