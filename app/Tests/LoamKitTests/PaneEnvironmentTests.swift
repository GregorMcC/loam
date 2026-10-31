import Testing
@testable import LoamKit

@Suite struct PaneEnvironmentTests {
    let bin = "/Applications/Loam.app/Contents/MacOS"
    let helpers = "/Applications/Loam.app/Contents/Helpers"

    func paneVariables(_ own: [String: String], inherited: [String: String]) -> [String: String] {
        PaneEnvironment.paneVariables(own, inherited: inherited, binFolder: bin, helpersFolder: helpers)
    }

    @Test func removesVariablesThatLeakFromTheHostTerminal() {
        let inherited = [
            "HOME": "/Users/me",
            "PATH": "/usr/bin:/bin",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_SSE_PORT": "1234",
            "CLAUDE_PID": "25479",
            "CLAUDE_EFFORT": "high",
            "SUPACODE_SURFACE_ID": "abc",
            "GHOSTTY_RESOURCES_DIR": "/Applications/supacode.app/Contents/Resources/ghostty",
            "GHOSTTY_BIN_DIR": "/Applications/supacode.app/Contents/MacOS",
            "TERMINFO": "/Applications/supacode.app/Contents/Resources/terminfo",
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "ghostty",
            "TERM_PROGRAM_VERSION": "1.3.1",
            "COLORTERM": "truecolor",
            "LOAM_PANE_SOCKET": "/tmp/other-pane.sock",
            "LOAM_PLOT": "plotaaaaab",
            "LOAM_HOME": "/tmp/loam-test",
        ]

        let clean = PaneEnvironment.scrubbed(inherited)

        #expect(clean == [
            "HOME": "/Users/me",
            "PATH": "/usr/bin:/bin",
            "LOAM_HOME": "/tmp/loam-test",
        ])
    }

    @Test func keepsVariablesThatOnlyShareAPrefixWord() {
        let inherited = ["CLAUDE_CONFIG_DIR": "/Users/me/.claude", "TERMINAL_EMULATOR": "x"]

        #expect(PaneEnvironment.scrubbed(inherited) == inherited)
    }

    @Test func thePanePathDropsTheFolderOfTheAppBinary() {
        let inherited = ["PATH": "/usr/bin:\(bin):/bin:\(bin)/", "HOME": "/Users/me"]

        // A PATH from the inherited environment, so it replaces the one libghostty extends (TAS-203).
        #expect(paneVariables(["LOAM_HOME": "/tmp/l"], inherited: inherited)
            == ["LOAM_HOME": "/tmp/l", "PATH": "/usr/bin:/bin", "GHOSTTY_BIN_DIR": helpers])
        // The pane's own PATH wins over the inherited one.
        #expect(paneVariables(["PATH": "\(bin):/opt/x"], inherited: inherited)["PATH"] == "/opt/x")
        // Another app's folder stays, and a PATH without the folder is kept as it is.
        #expect(paneVariables([:], inherited: ["PATH": "/Applications/Ghostty.app/Contents/MacOS:/bin"])["PATH"]
            == "/Applications/Ghostty.app/Contents/MacOS:/bin")
    }

    @Test func theShellIntegrationGetsTheFolderOfTheBundledCLI() {
        // The `path` shell feature appends GHOSTTY_BIN_DIR to PATH, so it must not be the app binary folder.
        #expect(paneVariables([:], inherited: ["PATH": "/bin"])["GHOSTTY_BIN_DIR"] == helpers)
        #expect(paneVariables(["GHOSTTY_BIN_DIR": bin], inherited: [:])["GHOSTTY_BIN_DIR"] == helpers)
    }

    @Test func thePanePathStartsFromThePathOfTheGhosttyConfig() {
        // A surface PATH replaces the PATH of your `env` lines, so Loam starts from it.
        let configured = PaneEnvironment.paneVariables([:], configured: "/opt/mine:\(bin)", inherited: ["PATH": "/bin"],
                                                       binFolder: bin, helpersFolder: helpers)
        #expect(configured["PATH"] == "/opt/mine")
        // The pane's own PATH still wins.
        #expect(PaneEnvironment.paneVariables(["PATH": "/own"], configured: "/opt/mine", inherited: [:],
                                              binFolder: bin, helpersFolder: helpers)["PATH"] == "/own")
    }

    @Test func thePanePathIsTheDefaultWhenNothingIsLeft() {
        // Without a PATH from Loam, libghostty keeps a PATH that is only the app binary folder.
        let fallback = ["A": "1", "GHOSTTY_BIN_DIR": helpers, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #expect(paneVariables(["A": "1"], inherited: ["PATH": bin]) == fallback)
        #expect(paneVariables(["A": "1"], inherited: [:]) == fallback)
        #expect(paneVariables(["A": "1", "PATH": ""], inherited: ["PATH": "/bin"]) == fallback)
        // Only empty entries are left: that PATH finds commands only in the current folder.
        #expect(paneVariables(["A": "1"], inherited: ["PATH": ":\(bin):"]) == fallback)
        #expect(paneVariables([:], inherited: ["PATH": ":/bin"])["PATH"] == ":/bin")
    }

    @Test func listsTheKeysToUnsetFromTheProcess() {
        let inherited = ["HOME": "/Users/me", "CLAUDECODE": "1", "TERMINFO": "/x"]

        #expect(PaneEnvironment.keysToRemove(from: inherited).sorted() == ["CLAUDECODE", "TERMINFO"])
    }
}
