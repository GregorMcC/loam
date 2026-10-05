import Foundation

/// The command line of a seeded pane (spec 8.2). It runs through your login shell, so `claude`
/// resolves on your normal PATH: `$SHELL -lc 'exec <loam> start <plot> [--worktree W] [--repo X] --session-id <uuid>'`.
/// `<loam>` is the absolute path of the binary that the app uses, so a pane and the app always
/// talk to the same core.
public enum PaneCommand {
    /// A new seeded session.
    public static func start(shell: String, loam: String, plot: String, repo: String? = nil, worktree: String? = nil,
                             plotFolder: Bool = false, sessionID: String) -> String {
        var args = [loam, "start", plot]
        if plotFolder { args.append("--plot-folder") }
        if let worktree { args += ["--worktree", worktree] }
        if let repo { args += ["--repo", repo] }
        args += ["--session-id", sessionID]
        return loginShell(shell, running: args)
    }

    /// Resumes a session that Loam started.
    public static func resume(shell: String, loam: String, sessionID: String) -> String {
        loginShell(shell, running: [loam, "resume", sessionID])
    }

    /// `$SHELL`, else `/bin/zsh`, the macOS default.
    public static func userShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    private static func loginShell(_ shell: String, running args: [String]) -> String {
        let inner = "exec " + args.map(quote).joined(separator: " ")
        return [shell, "-lc", inner].map(quote).joined(separator: " ")
    }

    /// Quotes one word for a POSIX shell. Plain words stay as they are.
    public static func quote(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
