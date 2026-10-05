/// The environment rules for a pane (spec 8.2).
///
/// libghostty copies the app's process environment when `ghostty_init` runs,
/// and every pane's child starts from that copy. So the app removes the leaked
/// variables from its own process before `ghostty_init`, and each pane adds its
/// own variables through the surface config.
public enum PaneEnvironment {
    /// Variables removed by exact name.
    static let removedNames: Set<String> = [
        "TERMINFO",
        "TERM",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "COLORTERM",
    ]

    /// Variables removed by prefix. `LOAM_PANE` covers the socket of a parent
    /// Loam pane, when Loam starts from inside a Loam pane.
    /// `CLAUDE` covers `CLAUDECODE`, `CLAUDE_CODE_*`, and the other variables
    /// that a Claude Code session sets for its tools, such as `CLAUDE_PID`.
    static let removedPrefixes = ["CLAUDE", "SUPACODE_", "GHOSTTY_", "LOAM_PANE"]

    /// Kept although a prefix matches: settings that you set yourself.
    static let keptNames: Set<String> = ["CLAUDE_CONFIG_DIR"]

    /// True when a pane must not inherit the variable from the host.
    public static func isLeaked(_ key: String) -> Bool {
        if keptNames.contains(key) { return false }
        return removedNames.contains(key) || removedPrefixes.contains { key.hasPrefix($0) }
    }

    /// The inherited environment with the leaked variables removed.
    public static func scrubbed(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { !isLeaked($0.key) }
    }

    /// The keys to unset from the app's process before `ghostty_init`.
    public static func keysToRemove(from inherited: [String: String]) -> [String] {
        inherited.keys.filter(isLeaked)
    }
}
