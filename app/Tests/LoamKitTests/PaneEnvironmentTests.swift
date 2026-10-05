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

    @Test func listsTheKeysToUnsetFromTheProcess() {
        let inherited = ["HOME": "/Users/me", "CLAUDECODE": "1", "TERMINFO": "/x"]

        #expect(PaneEnvironment.keysToRemove(from: inherited).sorted() == ["CLAUDECODE", "TERMINFO"])
    }
}
