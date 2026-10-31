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
        // A seeded session sets it for its tools. Loam started from inside that session must not
        // give it to a pane: a shell or a Home session belongs to no plot (ticket 99).
        "LOAM_PLOT",
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

    /// The variable that libghostty sets to the folder of the app's binary. The shell integration
    /// appends it to PATH when the `path` shell feature is on.
    public static let binFolderVariable = "GHOSTTY_BIN_DIR"

    /// The pane's own variables with a PATH that does not hold `binFolder`, and with
    /// `GHOSTTY_BIN_DIR` set to `helpersFolder` (TAS-203).
    ///
    /// libghostty appends the folder of the app's binary to each pane's PATH (`termio/Exec.zig`),
    /// and sets `GHOSTTY_BIN_DIR` to it. For Loam that folder holds the GUI binary `Loam`, and on a
    /// volume that ignores case a pane's `loam` can start a second copy of the app. libghostty
    /// applies the surface variables last, so the values here replace its values:
    ///
    /// - PATH comes from `own`, else from `inherited`, without `binFolder`. An empty PATH stays
    ///   out, because libghostty ignores an empty value.
    /// - `GHOSTTY_BIN_DIR` is the folder of the bundled `loam` CLI, so the shell integration appends
    ///   that folder. An empty value is not safe: the elvish integration checks only that the
    ///   variable exists. Your Ghostty config loads after Loam's, so Loam cannot turn the `path`
    ///   feature off.
    public static func paneVariables(
        _ own: [String: String], inherited: [String: String], binFolder: String, helpersFolder: String
    ) -> [String: String] {
        var variables = own
        variables[binFolderVariable] = helpersFolder
        guard let path = own["PATH"] ?? inherited["PATH"] else { return variables }
        let kept = path.split(separator: ":", omittingEmptySubsequences: false)
            .filter { $0 != binFolder && $0 != binFolder + "/" }
            .joined(separator: ":")
        variables["PATH"] = kept.isEmpty ? nil : kept
        return variables
    }
}
