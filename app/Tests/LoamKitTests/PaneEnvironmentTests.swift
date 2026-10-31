import Testing
@testable import LoamKit

@Suite struct PaneEnvironmentTests {
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
        let bin = "/Applications/Loam.app/Contents/MacOS"
        let inherited = ["PATH": "/usr/bin:\(bin):/bin:\(bin)/", "HOME": "/Users/me"]

        // A PATH from the inherited environment, so it replaces the one libghostty extends (TAS-203).
        #expect(PaneEnvironment.paneVariables(["LOAM_HOME": "/tmp/l"], inherited: inherited, binFolder: bin)
            == ["LOAM_HOME": "/tmp/l", "PATH": "/usr/bin:/bin"])
        // The pane's own PATH wins over the inherited one.
        #expect(PaneEnvironment.paneVariables(["PATH": "\(bin):/opt/x"], inherited: inherited, binFolder: bin)
            == ["PATH": "/opt/x"])
        // Another app's folder stays, and a PATH without the folder is kept as it is.
        #expect(PaneEnvironment.paneVariables([:], inherited: ["PATH": "/Applications/Ghostty.app/Contents/MacOS:/bin"],
                                              binFolder: bin) == ["PATH": "/Applications/Ghostty.app/Contents/MacOS:/bin"])
    }

    @Test func thePanePathStaysOutWhenNothingIsLeft() {
        let bin = "/Applications/Loam.app/Contents/MacOS"

        #expect(PaneEnvironment.paneVariables(["A": "1"], inherited: ["PATH": bin], binFolder: bin) == ["A": "1"])
        #expect(PaneEnvironment.paneVariables(["A": "1"], inherited: [:], binFolder: bin) == ["A": "1"])
    }

    @Test func listsTheKeysToUnsetFromTheProcess() {
        let inherited = ["HOME": "/Users/me", "CLAUDECODE": "1", "TERMINFO": "/x"]

        #expect(PaneEnvironment.keysToRemove(from: inherited).sorted() == ["CLAUDECODE", "TERMINFO"])
    }
}
