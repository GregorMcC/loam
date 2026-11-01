import AppKit
import Testing
@testable import LoamKit

@Suite struct KeyChordTests {
    @Test func parsesModifiersAndTheirAliases() {
        #expect(KeyChord.ghosttyTrigger("cmd+shift+p") == KeyChord([.command, .shift], "p"))
        #expect(KeyChord.ghosttyTrigger("super+p") == KeyChord(.command, "p"))
        #expect(KeyChord.ghosttyTrigger("command+opt+t") == KeyChord([.command, .option], "t"))
        #expect(KeyChord.ghosttyTrigger("control+alt+x") == KeyChord([.control, .option], "x"))
    }

    @Test func readsPhysicalW3CAndOldKeyNames() {
        #expect(KeyChord.ghosttyTrigger("ctrl+digit_1") == KeyChord(.control, "1"))
        #expect(KeyChord.ghosttyTrigger("ctrl+Digit1") == KeyChord(.control, "1"))
        #expect(KeyChord.ghosttyTrigger("ctrl+one") == KeyChord(.control, "1"))
        #expect(KeyChord.ghosttyTrigger("cmd+key_p") == KeyChord(.command, "p"))
        #expect(KeyChord.ghosttyTrigger("cmd+KeyP") == KeyChord(.command, "p"))
        #expect(KeyChord.ghosttyTrigger("cmd+P") == KeyChord(.command, "p"))
        #expect(KeyChord.ghosttyTrigger("cmd+bracket_left") == KeyChord(.command, "["))
        #expect(KeyChord.ghosttyTrigger("cmd+ArrowUp") == KeyChord(.command, "arrow_up"))
        #expect(KeyChord.ghosttyTrigger("cmd+arrow_up") == KeyChord(.command, "arrow_up"))
    }

    @Test func anEmptyPartIsALiteralPlus() {
        #expect(KeyChord.ghosttyTrigger("ctrl++") == KeyChord(.control, "+"))
    }

    @Test func rejectsWhatItCannotCompare() {
        #expect(KeyChord.ghosttyTrigger("") == nil)
        #expect(KeyChord.ghosttyTrigger("cmd+cmd+p") == nil)
        #expect(KeyChord.ghosttyTrigger("cmd+a+b") == nil)
        #expect(KeyChord.ghosttyTrigger("catch_all") == nil)
        #expect(KeyChord.ghosttyTrigger("cmd+shift") == nil)
    }

    @Test func takesTheFourModifiersOfAnEvent() {
        #expect(KeyChord.Mods([.command, .shift, .option, .control]) == [.command, .shift, .option, .control])
        #expect(KeyChord.Mods([.command, .capsLock, .function, .numericPad]) == .command)
    }

    @Test func readsTheChordOfAKeyEvent() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift, .capsLock], timestamp: 0, windowNumber: 0,
            context: nil, characters: "}", charactersIgnoringModifiers: "}", isARepeat: false, keyCode: 30))
        // The chord keeps Shift and takes the unshifted character of the key.
        #expect(KeyChord(event: event) == KeyChord([.command, .shift], "]"))
    }

    @Test func showsTheMacOSForm() {
        #expect(KeyChord([.command, .shift], "p").description == "⇧⌘P")
        #expect(KeyChord([.command, .option], "t").description == "⌥⌘T")
        #expect(KeyChord(.control, "1").description == "⌃1")
    }
}

@Suite struct KeyRouteTests {
    @Test func loamFixedKeysAlwaysGoToLoam() {
        #expect(LoamKeys.route(KeyChord(.command, "p"), isGhosttyBinding: true) == .loam(.quickSwitcher))
        #expect(LoamKeys.route(KeyChord(.command, "p"), isGhosttyBinding: false) == .loam(.quickSwitcher))
        #expect(LoamKeys.route(KeyChord([.command, .shift], "p"), isGhosttyBinding: true) == .loam(.quickSwitcherActions))
        #expect(LoamKeys.route(KeyChord(.command, "l"), isGhosttyBinding: false) == .loam(.nextPaneThatNeedsYou))
        #expect(LoamKeys.route(KeyChord(.command, "n"), isGhosttyBinding: true) == .loam(.newPlot))
        #expect(LoamKeys.route(KeyChord(.command, "b"), isGhosttyBinding: false) == .loam(.toggleSidebar))
        #expect(LoamKeys.route(KeyChord(.command, "i"), isGhosttyBinding: false) == .loam(.togglePlotPanel))
        #expect(LoamKeys.route(KeyChord([.command, .option], "t"), isGhosttyBinding: false) == .loam(.newShellTab))
        for n in 1...9 {
            #expect(LoamKeys.route(KeyChord(.control, "\(n)"), isGhosttyBinding: true) == .loam(.selectPlot(n)))
        }
    }

    @Test func ghosttyBindingsGoToTheMenuThenTheTerminal() {
        // ⌘T, ⌘D, ⌘[, ⌘1, ⌘W, ⌘Z keep their Ghostty meaning.
        for chord in [KeyChord(.command, "t"), KeyChord(.command, "d"), KeyChord(.command, "["),
                      KeyChord(.command, "1"), KeyChord(.command, "w"), KeyChord(.command, "z"),
                      KeyChord([.command, .shift], "t"), KeyChord([.command, .shift], "z"), KeyChord(.command, "k")] {
            #expect(LoamKeys.route(chord, isGhosttyBinding: true) == .menuThenTerminal, "\(chord)")
        }
    }

    /// TAS-46: while a page shows, ⌘[ and ⌘] go back and forward. In a terminal pane they stay Ghostty's goto_split keys,
    /// and the Back and Forward menu items show no key.
    @Test func thePageRouteTakesTheBracketKeysAndThePaneRouteKeepsThem() {
        #expect(LoamKeys.pageRoute(KeyChord(.command, "[")) == .goBack)
        #expect(LoamKeys.pageRoute(KeyChord(.command, "]")) == .goForward)
        // ⌘⇧[ and ⌘⇧] stay the tab keys, also on a page.
        #expect(LoamKeys.pageRoute(KeyChord([.command, .shift], "[")) == nil)
        #expect(LoamKeys.pageRoute(KeyChord([.control, .command], "arrow_left")) == nil)
        #expect(LoamKeys.route(KeyChord(.command, "["), isGhosttyBinding: true) == .menuThenTerminal)
        #expect(LoamKeys.route(KeyChord(.command, "]"), isGhosttyBinding: true) == .menuThenTerminal)
        #expect(LoamKeys.fixedKey(for: KeyChord(.command, "[")) == nil)
        #expect(LoamKeys.chord(for: .goBack) == nil && LoamKeys.chord(for: .goForward) == nil)
        #expect(LoamKeys.defaultChord(forGhosttyAction: "goto_split:previous") == KeyChord(.command, "["))
        #expect(LoamKeys.menuChord(forGhosttyBinding: KeyChord(.command, "]")) == KeyChord(.command, "]"))
    }

    /// TAS-46: over a page, mouse button 3 goes back and button 4 goes forward.
    @Test func theMouseBackAndForwardButtonsGoBackAndForwardOnAPage() {
        #expect(LoamKeys.pageMouseRoute(3) == .goBack)
        #expect(LoamKeys.pageMouseRoute(4) == .goForward)
        #expect(LoamKeys.pageMouseRoute(2) == nil)
        #expect(LoamKeys.pageMouseRoute(0) == nil)
    }

    @Test func otherKeysGoToTheTerminal() {
        #expect(LoamKeys.route(KeyChord(.control, "c"), isGhosttyBinding: false) == .terminal)
        #expect(LoamKeys.route(KeyChord([], "a"), isGhosttyBinding: false) == .terminal)
    }

    @Test func aGhosttyMenuItemNeverShowsALoamKey() {
        #expect(LoamKeys.menuChord(forGhosttyBinding: KeyChord(.command, "t")) == KeyChord(.command, "t"))
        #expect(LoamKeys.menuChord(forGhosttyBinding: KeyChord(.command, "p")) == nil)
        #expect(LoamKeys.menuChord(forGhosttyBinding: nil) == nil)
    }

    @Test func ghosttysDefaultMenuKeysKeepOffLoamKeys() {
        // Ticket 81: ⌘, is Settings, so Open Ghostty Config gives up Ghostty's default key.
        for item in LoamKeys.ghosttyMenuActions where item.action != "open_config" {
            #expect(LoamKeys.menuChord(forGhosttyBinding: item.defaultChord) == item.defaultChord, "\(item.action)")
        }
        #expect(LoamKeys.defaultChord(forGhosttyAction: "goto_tab:3") == KeyChord(.command, "3"))
        #expect(LoamKeys.defaultChord(forGhosttyAction: "no_such_action") == nil)
    }

    @Test func everyFixedKeyIsDistinct() {
        #expect(Set(LoamKeys.fixed.map(\.chord)).count == LoamKeys.fixed.count)
        #expect(LoamKeys.chord(for: .toggleSidebar) == KeyChord(.command, "b"))
    }
}

@Suite(.temporaryFolders) struct GhosttyConfigFilesTests {
    let home = "/Users/me"

    @Test func searchesTheXDGFolderThenApplicationSupportInGhosttysOrder() {
        #expect(GhosttyConfigFiles.defaultCandidates(environment: [:], home: home) == [
            "/Users/me/.config/ghostty/config",
            "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(GhosttyConfigFiles.defaultCandidates(environment: ["XDG_CONFIG_HOME": "/x"], home: home).first
            == "/x/ghostty/config")
    }

    @Test func loadsOnlyTheFilesThatExistAndLoamDefaultsFirst() {
        let user = GhosttyConfigFiles.userDefault(environment: [:], home: home) {
            $0.hasSuffix("/.config/ghostty/config") || $0.hasSuffix("com.mitchellh.ghostty/config.ghostty")
        }
        #expect(user == ["/Users/me/.config/ghostty/config",
                         "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty"])
        let files = GhosttyConfigFiles(defaults: ["/app/loam-defaults"], user: user)
        #expect(files.loadOrder.first == "/app/loam-defaults")
        #expect(files.loadOrder.count == 3)
    }

    @Test func readsLinesAsGhosttyDoes() {
        let text = """
        # a comment
        font-family = "JetBrains Mono"
        keybind=cmd+p=new_tab

          background = #102030
        not a pair
        """
        let entries = GhosttyConfigFiles.entries(in: text, file: "/c")
        #expect(entries.map(\.key) == ["font-family", "keybind", "background"])
        #expect(entries[0].value == "JetBrains Mono")
        #expect(entries[1].value == "cmd+p=new_tab")
        #expect(entries[2].number == 5)
    }

    @Test func readsThePathOfTheEnvLines() {
        func path(_ text: String) -> String? {
            GhosttyConfigFiles.environmentPath(in: GhosttyConfigFiles.entries(in: text, file: "/c"))
        }
        #expect(path("font-size = 13") == nil)
        #expect(path("env = PATH=/a:/b\nenv = LANG=C") == "/a:/b")
        #expect(path("env = PATH=/a\nenv = PATH=/b") == "/b")
        // `PATH=` removes the variable, and an empty `env =` removes every variable.
        #expect(path("env = PATH=/a\nenv = PATH=") == nil)
        #expect(path("env = PATH=/a\nenv =\nenv = LANG=C") == nil)
        #expect(path("env = \"PATH=/a b\"") == "/a b")
    }

    @Test func findsIncludesRelativeToTheirFile() {
        let text = """
        config-file = keys.conf
        config-file = ?~/opt/theme.conf
        config-file = "/abs/other"
        """
        #expect(GhosttyConfigFiles.includes(in: text, file: "/cfg/ghostty/config", home: home) == [
            "/cfg/ghostty/keys.conf", "/Users/me/opt/theme.conf", "/abs/other",
        ])
    }

    @Test func expandsIncludesOnceAndSkipsMissingFiles() {
        let files = ["/a": "config-file = b\nconfig-file = missing", "/b": "config-file = /a"]
        #expect(GhosttyConfigFiles.expand(["/a"], home: home) { files[$0] } == ["/a", "/b"])
    }

    @Test func aKeybindOfALoamKeyIsAClash() {
        let text = """
        keybind = cmd+p=new_tab
        keybind = ctrl+one=goto_tab:1
        keybind = global:cmd+l=toggle_quick_terminal
        keybind = cmd+i>x=new_split:right
        keybind = super+alt+t=new_window
        """
        let clashes = GhosttyConfigFiles.clashes(in: GhosttyConfigFiles.entries(in: text, file: "/c"))
        #expect(clashes.map(\.key.command) == [.quickSwitcher, .selectPlot(1), .nextPaneThatNeedsYou,
                                                .togglePlotPanel, .newShellTab])
        #expect(clashes[0].entry.number == 1)
        #expect(clashes[0].description
            == "Ghostty config /c line 1: keybind = cmd+p=new_tab uses ⌘P. Loam uses ⌘P for Quick Switcher, so Loam's key wins.")
    }

    @Test func theSameMeaningOrAnUnbindIsNoClash() {
        let text = """
        keybind = cmd+n=new_window
        keybind = cmd+shift+p=toggle_command_palette
        keybind = cmd+b=unbind
        keybind = cmd+t=new_tab
        keybind = cmd+==equalize_splits
        keybind = clear
        keybind = chain=new_tab
        keybind = cmd+shift+,=reload_config
        """
        #expect(GhosttyConfigFiles.clashes(in: GhosttyConfigFiles.entries(in: text, file: "/c")).isEmpty)
    }

    @Test func aKeyOtherThanTheFixedOneIsNoClash() {
        let text = "keybind = cmd+n=new_tab\nkeybind = ctrl+shift+n=new_tab"
        let clashes = GhosttyConfigFiles.clashes(in: GhosttyConfigFiles.entries(in: text, file: "/c"))
        // ⌘N to another action clashes. ⌃⇧N is not a Loam key.
        #expect(clashes.map(\.key.command) == [.newPlot])
    }

    @Test func watchesTheFoldersThatExist() {
        let existing: Set = ["/", "/a", "/home", "/home/me"]
        let plan = GhosttyConfigFiles.watchPlan(
            for: ["/a/config", "/a/config.ghostty", "/home/me/.config/ghostty/config"]) { existing.contains($0) }
        // ~/.config/ghostty does not exist yet, so its nearest folder that exists is a parent.
        #expect(plan.folders == ["/a"])
        #expect(plan.parents == ["/home/me"])
    }

    @Test func aMissingConfigFileDoesNotWatchItsGrandparentFolders() {
        // No Ghostty install: neither config folder exists.
        let home = "/Users/me"
        let existing: Set = ["/", "/Users", home, home + "/.config", home + "/Library", home + "/Library/Application Support"]
        let files = GhosttyConfigFiles.defaultCandidates(environment: [:], home: home)
        let plan = GhosttyConfigFiles.watchPlan(for: files) { existing.contains($0) }
        // Nothing gets a watch with subfolders. Only the entries of the nearest folders count.
        #expect(plan.folders.isEmpty)
        #expect(plan.parents == [home + "/.config", home + "/Library/Application Support"])
        #expect(!plan.parents.contains(home) && !plan.parents.contains("/Users"))

        // A parent that already holds a config file needs no second watch.
        let mixed = GhosttyConfigFiles.watchPlan(for: ["/a/config", "/a/b/c/keys"]) { ["/", "/a"].contains($0) }
        #expect(mixed.folders == ["/a"])
        #expect(mixed.parents.isEmpty)
    }

    @Test func theFilterMatchesTheRealPathOfAFile() throws {
        // FSEvents reports /private/var for a file under /var.
        let folder = temporaryFolder("filter")
        let file = folder.appendingPathComponent("config").path
        let real = (realpath(folder.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? folder.path) + "/config"
        let filter = ConfigEventFilter(files: [file])
        #expect(filter.accepts(file))
        #expect(filter.accepts(real))
        #expect(filter.accepts((real as NSString).deletingLastPathComponent + "/themes/nord"))
        #expect(!filter.accepts(real + "~"))
    }

    @Test func countsOnlyConfigAndThemeEvents() {
        let files = ["/a/config", "/a/keys"]
        #expect(ConfigEventFilter(files: files).accepts("/a/config"))
        #expect(ConfigEventFilter(files: files).accepts("/a/themes/nord"))
        #expect(!ConfigEventFilter(files: files).accepts("/b/themes/nord"))
        #expect(!ConfigEventFilter(files: files).accepts("/a/state.json"))
        #expect(!ConfigEventFilter(files: files).accepts("/a/config~"))
    }
}

@Suite struct LastGoodConfigTests {
    @Test func aGoodConfigReplacesTheOldOne() {
        var state = LastGoodConfig<String>()
        let first = state.offer("one", errors: [])
        #expect(first.outcome == .applied && first.release == nil)
        let (outcome, release) = state.offer("two", errors: [])
        #expect(outcome == .applied)
        #expect(release == "one")
        #expect(state.current == "two")
    }

    @Test func aConfigWithErrorsKeepsTheLastGoodOne() {
        var state = LastGoodConfig<String>()
        _ = state.offer("good", errors: [])
        let (outcome, release) = state.offer("bad", errors: ["background: invalid value"])
        #expect(outcome == .keptLastGood(["background: invalid value"]))
        #expect(release == "bad")
        #expect(state.current == "good")
        #expect(state.errors == ["background: invalid value"])
    }

    @Test func theFirstConfigIsUsedEvenWithErrors() {
        var state = LastGoodConfig<String>()
        let (outcome, release) = state.offer("partial", errors: ["unknown field"])
        #expect(outcome == .appliedWithErrors(["unknown field"]))
        #expect(release == nil)
        #expect(state.current == "partial")
    }

    @Test func withNoGoodConfigYetANewConfigWithErrorsStillApplies() {
        // A typo at launch must not freeze the config: later edits apply until the typo is fixed.
        var state = LastGoodConfig<String>()
        _ = state.offer("typo", errors: ["x"])
        let next = state.offer("typo and a new font size", errors: ["x"])
        #expect(next.outcome == .appliedWithErrors(["x"]) && next.release == "typo")
        #expect(state.current == "typo and a new font size")
        let fixed = state.offer("fixed", errors: [])
        #expect(fixed.outcome == .applied && fixed.release == "typo and a new font size")
        let broken = state.offer("broken", errors: ["y"])
        #expect(broken.outcome == .keptLastGood(["y"]) && broken.release == "broken")
        #expect(state.current == "fixed")
    }

    @Test func aFixedConfigClearsTheErrors() {
        var state = LastGoodConfig<String>()
        _ = state.offer("good", errors: [])
        _ = state.offer("bad", errors: ["x"])
        let fixed = state.offer("fixed", errors: [])
        #expect(fixed.outcome == .applied && fixed.release == "good")
        #expect(state.errors.isEmpty)
    }
}

@MainActor
@Suite(.waitLimit, .temporaryFolders) struct ConfigWatchTests {
    @Test func aBurstOfEventsIsOneReload() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let watch = ConfigWatch(debounce: .milliseconds(50)) { _ in stream }
        var reloads = 0
        watch.onChange = { reloads += 1 }
        watch.watch(["/a/config"])
        // Wait for the reload, then several debounces more, so a second reload from the same burst would show.
        func settle(at count: Int) async throws {
            await waitUntil("reload \(count)") { reloads >= count }
            try await Task.sleep(for: .milliseconds(300))
        }
        for _ in 0..<5 { continuation.yield() }
        try await settle(at: 1)
        #expect(reloads == 1)
        continuation.yield()
        try await settle(at: 2)
        #expect(reloads == 2)
        watch.stop()
    }

    @Test func aNewFileListRestartsTheWatch() {
        let made = Recorder()
        let watch = ConfigWatch { files in
            made.add(files)
            return AsyncStream { _ in }
        }
        watch.watch(["/a"])
        watch.watch(["/a"])
        watch.watch(["/a", "/b"])
        #expect(made.lists == [["/a"], ["/a", "/b"]])
        watch.stop()
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [[String]] = []
        var lists: [[String]] { lock.withLock { value } }
        func add(_ files: [String]) { lock.withLock { value.append(files) } }
    }

    @Test(.outsideASandbox) func reloadsWhenTheFileChangesOnDisk() async throws {
        let folder = temporaryFolder("config-watch")
        let file = folder.appendingPathComponent("config").path
        try "background = #000000\n".write(toFile: file, atomically: true, encoding: .utf8)
        let watch = ConfigWatch(debounce: .milliseconds(50))
        var reloads = 0
        watch.onChange = { reloads += 1 }
        watch.watch([file])
        try await Task.sleep(for: .milliseconds(300))
        try "background = #ffffff\n".write(toFile: file, atomically: true, encoding: .utf8)
        await waitUntil("the reload") { reloads >= 1 }
        watch.stop()
    }

    @Test(.outsideASandbox) func followsAConfigFileThatBecomesALink() async throws {
        let fm = FileManager.default
        let root = temporaryFolder("config-link")
        try fm.createDirectory(at: root.appendingPathComponent("ghostty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("ghostty/config").path
        let target = root.appendingPathComponent("dotfiles/config").path
        try "background = #000000\n".write(toFile: file, atomically: true, encoding: .utf8)
        try "background = #111111\n".write(toFile: target, atomically: true, encoding: .utf8)
        let watch = ConfigWatch(debounce: .milliseconds(50))
        var reloads = 0
        watch.onChange = { reloads += 1 }
        watch.watch([file])
        try await Task.sleep(for: .milliseconds(300))

        // A dotfiles tool replaces the file with a link.
        try fm.removeItem(atPath: file)
        try fm.createSymbolicLink(atPath: file, withDestinationPath: target)
        await waitUntil("the reload") { reloads >= 1 }

        // The watch follows the link: an edit of the target is seen.
        try await Task.sleep(for: .milliseconds(500))
        let seen = reloads
        try "background = #222222\n".write(toFile: target, atomically: true, encoding: .utf8)
        await waitUntil("the reload after the edit") { reloads > seen }
        watch.stop()
    }

    @Test(.outsideASandbox) func seesAConfigMadeInAFolderThatDidNotExist() async throws {
        let root = temporaryFolder("config-new")
        let file = root.appendingPathComponent("ghostty/config").path
        let watch = ConfigWatch(debounce: .milliseconds(50))
        var reloads = 0
        watch.onChange = { reloads += 1 }
        watch.watch([file])
        try await Task.sleep(for: .milliseconds(300))

        // A write in a subfolder of the parent is not seen: the parent has no watch on subfolders.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(to: other.appendingPathComponent("file"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(reloads == 0)

        // The config folder and file appear (⌘, does this): the config loads.
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "background = #ffffff\n".write(toFile: file, atomically: true, encoding: .utf8)
        await waitUntil("the reload") { reloads >= 1 }

        // The watch moved to the new folder, so a later edit is seen too.
        try await Task.sleep(for: .milliseconds(500))
        let seen = reloads
        try "background = #000000\n".write(toFile: file, atomically: true, encoding: .utf8)
        await waitUntil("the reload after the edit") { reloads > seen }
        watch.stop()
    }
}

@Suite struct SettingsKeyTests {
    @Test func commandCommaOpensSettings() {
        #expect(LoamKeys.route(KeyChord(.command, ","), isGhosttyBinding: true) == .loam(.openSettings))
        #expect(LoamKeys.chord(for: .openSettings) == KeyChord(.command, ","))
    }

    @Test func openGhosttyConfigLosesItsDefaultKey() {
        let chord = LoamKeys.defaultChord(forGhosttyAction: "open_config")
        #expect(LoamKeys.menuChord(forGhosttyBinding: chord) == nil)
        #expect(LoamKeys.menuChord(forGhosttyBinding: KeyChord([.command, .option], ",")) == KeyChord([.command, .option], ","))
        #expect(LoamKeys.menuChord(forGhosttyBinding: LoamKeys.defaultChord(forGhosttyAction: "reload_config")) == KeyChord([.command, .shift], ","))
    }
}
