/// The app's GUI binary `Loam.app/Contents/MacOS/Loam` refuses a `loam` CLI command (TAS-211).
///
/// A volume that ignores case finds the GUI binary for `loam`, so a script that runs `loam export --json`
/// can start a full second copy of the app, with a Dock icon, that never exits. macOS starts the app with
/// arguments that start with one `-` (such as `-NSDocumentRevisionsDebugMode YES` or `-psn_0_12345`). A CLI
/// command starts with a word, a long flag such as the global `--json` or `--actor`, or `-h`. So a first
/// argument that does not start with `-`, that starts with `--`, or that is `-h` is a CLI command.
public enum CLIArguments {
    /// The exit status of a refused launch: a usage error.
    public static let exitStatus: Int32 = 2

    /// The line for stderr when `arguments` (program name first, as in `CommandLine.arguments`) hold a
    /// CLI command. Nil when the app starts.
    public static func refusal(arguments: [String], bundledCLI: String) -> String? {
        guard let first = arguments.dropFirst().first,
              !first.hasPrefix("-") || first.hasPrefix("--") || first == "-h" else { return nil }
        return "This is the Loam app, not the loam CLI. Run the CLI at \(bundledCLI).\n"
    }
}
