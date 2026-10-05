import Foundation

/// What a Ghostty config load did.
public enum ConfigOutcome: Equatable, Sendable {
    /// The new config is in use.
    case applied
    /// The load had errors, and no earlier load was free of them. With no good config to
    /// keep, the app uses this one: libghostty skips the bad lines and keeps the rest.
    case appliedWithErrors([String])
    /// The new config had errors. The last good config stays in use.
    case keptLastGood([String])

    /// The errors of the load. Empty when it had none.
    public var errors: [String] {
        switch self {
        case .applied: []
        case .appliedWithErrors(let errors), .keptLastGood(let errors): errors
        }
    }
}

/// The rule for a config load (spec 8.3): a config with errors never replaces a good one.
/// `Config` is the config handle. The terminal runtime uses `ghostty_config_t`, and the tests use strings.
public struct LastGoodConfig<Config> {
    /// The config in use.
    public private(set) var current: Config?
    /// The errors of the last load. Empty when it had none.
    public private(set) var errors: [String] = []

    public init() {}

    /// Offers a newly loaded config. Returns what happened, and the handle that the caller
    /// must free now: the replaced config, or the rejected one.
    /// A config with errors replaces another config with errors: until one load has no errors,
    /// there is no good config to keep, and your newest edits apply.
    public mutating func offer(_ config: Config, errors: [String]) -> (outcome: ConfigOutcome, release: Config?) {
        self.errors = errors
        let old = current
        if !errors.isEmpty, hasGood { return (.keptLastGood(errors), config) }
        current = config
        hasGood = errors.isEmpty
        return (errors.isEmpty ? .applied : .appliedWithErrors(errors), old)
    }

    /// True when the config in use had no errors.
    public private(set) var hasGood = false
}
