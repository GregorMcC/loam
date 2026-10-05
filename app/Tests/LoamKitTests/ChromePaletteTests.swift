import AppKit
import Testing
@testable import LoamKit

/// Tickets 68 and 70: the chrome colors follow the terminal background.
@Suite struct ChromePaletteTests {
    static let nordRose: UInt32 = 0x20242b
    static let nordRoseLight: UInt32 = 0xeceff4
    static let lightGrey = OKLCH(l: 0.80, c: 0, h: 0).hex
    static let midGrey: UInt32 = 0x808080

    /// Terminal backgrounds of common Ghostty themes, and the extremes.
    static let darkBackgrounds: [UInt32] = [
        nordRose, 0x2e3440 /* Nord */, 0x282a36 /* Dracula */, 0x1e1e2e /* Catppuccin Mocha */,
        0x1a1b26 /* Tokyo Night */, 0x282828 /* Gruvbox */, 0x002b36 /* Solarized dark */, 0x282c34 /* One Dark */,
        0x272822 /* Monokai */, 0x000000, 0x4c566a, 0x606060, 0x0000aa, 0x800000, 0x12110f /* Loam Night */,
    ]
    static let lightBackgrounds: [UInt32] = [
        nordRoseLight, 0xeff1f5 /* Catppuccin Latte */, 0xfbf1c7 /* Gruvbox light */,
        0xfdf6e3 /* Solarized light */, 0xffffff, midGrey, lightGrey, 0xffff00, 0xfcfbf8 /* Loam Day */,
    ]
    static let allBackgrounds = darkBackgrounds + lightBackgrounds

    private func token(_ name: String, dark: Bool) -> UInt32 {
        let t = LoamTheme.colorTokens.first { $0.name == name }!
        return dark ? t.night : t.day
    }

    private func lightness(_ hex: UInt32) -> Double { OKLCH(hex).l }
    private func name(_ hex: UInt32) -> String { String(hex, radix: 16) }

    @Test func loamsOwnBedrockGivesLoamsOwnTokens() {
        for dark in [true, false] {
            let surfaces = ChromeSurfaces.derive(background: token("bedrock", dark: dark))
            #expect(surfaces.isDark == dark)
            for name in ChromeSurfaces.tokenNames {
                #expect(surfaces.value(of: name) == token(name, dark: dark), "\(name) dark \(dark)")
            }
        }
    }

    @Test func bedrockIsTheTerminalBackground() {
        for background in Self.allBackgrounds {
            #expect(ChromeSurfaces.derive(background: background).bedrock == background)
        }
    }

    @Test func nightOrDayFollowsTheBackgroundAsGhosttyDoes() {
        for background in Self.darkBackgrounds { #expect(ChromeSurfaces.isDark(background), "\(name(background))") }
        for background in Self.lightBackgrounds { #expect(!ChromeSurfaces.isDark(background), "\(name(background))") }
    }

    /// Night steps lighter from the background: horizon-o, horizon-a, horizon-b, then rule.
    @Test func nightStepsLighter() {
        let s = ChromeSurfaces.derive(background: Self.nordRose)
        #expect(s.isDark)
        #expect([s.bedrock, s.horizonO, s.horizonA, s.horizonB, s.rule] == [0x20242b, 0x292d34, 0x2e333a, 0x373b43, 0x474b53])
    }

    /// Day steps darker: horizon-a, horizon-o, then rule. horizon-b is raised, so a little lighter.
    @Test func dayStepsDarker() {
        let s = ChromeSurfaces.derive(background: Self.nordRoseLight)
        #expect(!s.isDark)
        #expect([s.bedrock, s.horizonO, s.horizonA, s.horizonB, s.rule] == [0xeceff4, 0xdcdee3, 0xe4e7ec, 0xf0f3f8, 0xc4c7cc])
    }

    /// The review finding on the prototype: for every background, each horizon sits on the right
    /// side of `bedrock`, whatever its lightness. A mid-tone dark and a light grey below the old
    /// clamp are in the list (`0x808080`, and a grey at OKLCH L 0.80).
    @Test func horizonsStayOnTheRightSideOfBedrock() {
        let eps = 0.002
        for background in Self.allBackgrounds {
            let s = ChromeSurfaces.derive(background: background)
            let l = [s.bedrock, s.horizonO, s.horizonA, s.horizonB, s.rule].map(lightness)
            let why = "\(name(background)): \(l)"
            if s.isDark {
                #expect(l[1] >= l[0] - eps && l[2] >= l[1] - eps && l[3] >= l[2] - eps, "\(why)")
                #expect(l[4] >= l[0] - eps, "\(why)")
            } else {
                #expect(l[1] <= l[0] + eps && l[2] <= l[0] + eps, "\(why)")
                #expect(l[1] <= l[2] + eps, "o is darker than a: \(why)")
                #expect(l[4] <= l[1] + eps, "rule is the darkest: \(why)")
                #expect(l[3] >= l[0] - eps, "b is raised: \(why)")
            }
        }
        let grey = ChromeSurfaces.derive(background: Self.lightGrey)
        #expect(lightness(grey.horizonO) < lightness(grey.bedrock) - 0.02, "Day steps darker on a grey of L 0.80")
        let mid = ChromeSurfaces.derive(background: Self.midGrey)
        #expect(lightness(mid.horizonO) <= lightness(mid.bedrock) + 0.002, "no horizon passes bedrock on #808080")
    }

    /// The surfaces keep the background's hue, so the chrome and the panes read as one palette.
    @Test func surfacesKeepTheHue() {
        let hue = OKLCH(Self.nordRose).h
        let s = ChromeSurfaces.derive(background: Self.nordRose)
        for value in [s.horizonO, s.horizonA, s.horizonB, s.rule] {
            #expect(abs(OKLCH(value).h - hue) < 0.15, "\(name(value))")
        }
    }

    /// The frame ground: bedrock in Night, horizon-o in Day.
    @Test func theFrameIsBedrockInNightAndHorizonOInDay() {
        for background in Self.allBackgrounds {
            let s = ChromeSurfaces.derive(background: background)
            #expect(s.frame == (s.isDark ? s.bedrock : s.horizonO), "\(name(background))")
        }
    }

    /// The Day frame is darker than bedrock by a step the eye sees, so the glass edge shows.
    @Test func theDayFrameIsADistinctStepFromBedrockForLightThemes() {
        for background in [Self.nordRoseLight, 0xeff1f5, 0xfdf6e3, 0xffffff, Self.lightGrey] as [UInt32] {
            let s = ChromeSurfaces.derive(background: background)
            #expect(lightness(s.bedrock) - lightness(s.frame) > 0.03, "\(name(background))")
        }
    }

    // MARK: Contrast

    /// Small text reaches 4.5:1 on every text surface of every derived set, and of Loam's own:
    /// `ink`, `ink-muted`, and the four state hues. `ink-faint` reaches 3:1. `on-moss` reads on `moss`.
    @Test func textReachesAAOnEveryTextSurface() {
        for background in Self.allBackgrounds {
            let s = ChromeSurfaces.derive(background: background)
            for surface in s.textSurfaces {
                let where_ = "\(name(surface)) from \(name(background))"
                for token in ["ink", "ink-muted", "moss", "needs-you", "done-unread", "rust"] {
                    #expect(ChromeSurfaces.contrast(s.value(of: token)!, surface) >= 4.5, "\(token) on \(where_)")
                }
                #expect(ChromeSurfaces.contrast(s.inkFaint, surface) >= 3, "ink-faint on \(where_)")
            }
            #expect(ChromeSurfaces.contrast(token("on-moss", dark: s.isDark), s.moss) >= 4.5, "on-moss on moss from \(name(background))")
        }
    }

    /// The prototype's gaps: Nord gave `ink-muted` 3.55:1 and `moss` 4.4:1.
    @Test func nordNoLongerHasTheGaps() {
        let s = ChromeSurfaces.derive(background: 0x2e3440)
        let worstMuted = s.textSurfaces.map { ChromeSurfaces.contrast(s.inkMuted, $0) }.min()!
        #expect(worstMuted >= 4.5)
    }

    @Test func inkMutedStaysBelowInkWhenThereIsRoom() {
        for background in [Self.nordRose, 0x282a36, Self.nordRoseLight, 0xfdf6e3] as [UInt32] {
            let s = ChromeSurfaces.derive(background: background)
            #expect(ChromeSurfaces.contrast(s.ink, s.bedrock) > ChromeSurfaces.contrast(s.inkMuted, s.bedrock), "\(name(background))")
        }
    }

    @Test func contrastLiftMovesLightnessOnlyAndStopsAtTheRatio() {
        let surface: UInt32 = 0x2e3440
        let start = OKLCH(l: 0.5, c: 0.1, h: 2.0)
        let lifted = ChromeSurfaces.lift(start, dark: true, ratio: 4.5, on: [surface])
        #expect(ChromeSurfaces.contrast(lifted, surface) >= 4.5)
        let result = OKLCH(lifted)
        #expect(result.l > start.l)
        #expect(abs(result.h - start.h) < 0.1, "the hue stays")
        // One step less would miss the ratio: the lift goes only as far as needed.
        let below = OKLCH(l: result.l - 0.01, c: start.c, h: start.h).hex
        #expect(ChromeSurfaces.contrast(below, surface) < 4.5)
        // A day lift goes darker.
        let day = ChromeSurfaces.lift(OKLCH(l: 0.8, c: 0.1, h: 2.0), dark: false, ratio: 4.5, on: [0xeceff4])
        #expect(OKLCH(day).l < 0.8)
        #expect(ChromeSurfaces.contrast(day, 0xeceff4) >= 4.5)
        // A color that already passes is returned unchanged.
        #expect(ChromeSurfaces.lift(OKLCH(0xede6da), dark: true, ratio: 4.5, on: [0x12110f], keeping: 0xede6da) == 0xede6da)
        // No lightness can reach the ratio: pure white or black.
        #expect(ChromeSurfaces.lift(start, dark: true, ratio: 30, on: [0x000000]) == 0xffffff)
        #expect(ChromeSurfaces.lift(start, dark: false, ratio: 30, on: [0xffffff]) == 0x000000)
    }

    // MARK: Ink tint

    /// The ink is neutral with a slight tint: the theme hue at low chroma. A grey theme gives a grey ink.
    @Test func inkTakesAFaintTintOfTheThemeHue() {
        for background in [Self.nordRose, 0x2e3440, 0x282a36, Self.nordRoseLight, 0xfdf6e3] as [UInt32] {
            let base = OKLCH(background)
            let s = ChromeSurfaces.derive(background: background)
            for ink in [s.ink, s.inkMuted, s.inkFaint] {
                let c = OKLCH(ink)
                #expect(c.c <= ChromeSurfaces.maxInkChroma + 0.004, "\(name(ink)) chroma \(c.c)")
                if c.c > 0.004, c.l > 0.05, c.l < 0.97 { #expect(abs(c.h - base.h) < 0.5, "\(name(ink)) hue from \(name(background))") }
            }
            #expect(OKLCH(s.ink).c < OKLCH(token("ink", dark: s.isDark)).c + 0.004, "not louder than Loam's warm ink")
        }
        for grey in [Self.midGrey, Self.lightGrey, 0x000000, 0xffffff] as [UInt32] {
            let s = ChromeSurfaces.derive(background: grey)
            for ink in [s.ink, s.inkMuted, s.inkFaint] { #expect(OKLCH(ink).c < 0.004, "\(name(ink)) on grey \(name(grey))") }
        }
    }

    @Test func theStateHuesKeepTheirHue() {
        for background in Self.allBackgrounds {
            let s = ChromeSurfaces.derive(background: background)
            for token in ["moss", "needs-you", "done-unread", "rust"] {
                let source = OKLCH(self.token(token, dark: s.isDark)), got = OKLCH(s.value(of: token)!)
                guard got.l > 0.05, got.l < 0.97 else { continue }
                #expect(abs(got.h - source.h) < 0.12, "\(token) on \(name(background))")
            }
        }
    }

    /// Where a state hue already reads, it does not move.
    @Test func aStateHueThatReadsStaysAsItIs() {
        let s = ChromeSurfaces.derive(background: Self.nordRose)
        #expect(s.moss == token("moss", dark: true))
        #expect(s.needsYou == token("needs-you", dark: true))
    }

    @Test func contrastIsTheWCAGRatio() {
        #expect(abs(ChromeSurfaces.contrast(0x000000, 0xffffff) - 21) < 0.01)
        #expect(ChromeSurfaces.contrast(0x777777, 0x777777) == 1)
    }

    @Test func oklchRoundTrips() {
        for hex: UInt32 in [0x20242b, 0xeceff4, 0x12110f, 0x94c26e, 0xffffff, 0x000000] {
            #expect(OKLCH(hex).hex == hex, "\(String(hex, radix: 16))")
        }
    }

    // MARK: The palette

    @Test func thePaletteFollowsOneBackgroundForItsAppearance() {
        let palette = ChromePalette()
        #expect(palette.value(of: "horizon-o", dark: true) == nil)
        #expect(palette.follow(terminalBackground: Self.nordRose))
        #expect(!palette.follow(terminalBackground: Self.nordRose), "the same background changes nothing")
        #expect(palette.value(of: "horizon-o", dark: true) == 0x292d34)
        #expect(palette.value(of: "bedrock", dark: true) == Self.nordRose)
        // Day gives Loam's token until a light background arrives.
        #expect(palette.value(of: "horizon-o", dark: false) == nil)
        #expect(palette.value(of: "needs-you-wash", dark: true) == nil, "a wash does not follow")
        #expect(palette.follow(terminalBackground: Self.nordRoseLight))
        #expect(palette.value(of: "horizon-o", dark: false) == 0xdcdee3)
        #expect(palette.value(of: "horizon-o", dark: true) == nil)
        #expect(palette.follow(terminalBackground: nil))
        #expect(palette.current == nil)
    }

    @Test func aChangePostsOneNotification() {
        let palette = ChromePalette()
        let count = Counter()
        let token = NotificationCenter.default.addObserver(forName: ChromePalette.didChange, object: palette, queue: nil) { _ in count.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        palette.follow(terminalBackground: Self.nordRose)
        palette.follow(terminalBackground: Self.nordRose)
        #expect(count.value == 1, "the same background posts nothing")
        palette.follow(terminalBackground: nil)
        #expect(count.value == 2)
        palette.follow(terminalBackground: nil)
        #expect(count.value == 2)
    }

    @MainActor @Test func aViewObservesThePaletteAndEndsWithTheView() {
        let palette = ChromePalette()
        let count = Counter()
        var view: NSView? = NSView()
        var observer = view?.observeChromePalette(palette) { _ in count.value += 1 }
        palette.follow(terminalBackground: Self.nordRose)
        #expect(count.value == 1)
        palette.follow(terminalBackground: Self.nordRoseLight)
        #expect(count.value == 2)
        view = nil
        palette.follow(terminalBackground: nil)
        #expect(count.value == 2, "a view that is gone gets no call")
        observer = nil
        _ = observer
    }

    @Test func aSurfaceColorResolvesThroughThePalette() {
        let palette = ChromePalette()
        let color = LoamTheme.surface("horizon-o", night: 0x1b1916, day: 0xeeeae2, palette: palette)
        #expect(resolved(color, .darkAqua) == 0x1b1916)
        palette.follow(terminalBackground: Self.nordRose)
        #expect(resolved(color, .darkAqua) == 0x292d34)
        #expect(resolved(color, .aqua) == 0xeeeae2)
    }

    @Test func theWindowOpacityFollowsTheConfigAndPostsOnAChange() {
        let palette = ChromePalette()
        let count = Counter()
        let token = NotificationCenter.default.addObserver(forName: ChromePalette.didChange, object: palette, queue: nil) { _ in count.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(palette.windowOpacity == 1 && !palette.isTranslucent)
        #expect(!palette.follow(windowOpacity: 1), "the same opacity posts nothing")
        #expect(palette.follow(windowOpacity: 0.97))
        #expect(palette.isTranslucent && count.value == 1)
        palette.follow(windowOpacity: 7)
        #expect(palette.windowOpacity == 1 && count.value == 2, "an opacity over 1 is 1")
        palette.follow(windowOpacity: -.infinity)
        palette.follow(windowOpacity: .nan)
        #expect(palette.windowOpacity == 1, "a value that is not a number is 1")
    }

    @Test func theFrameUnderTheSidebarGlassMakesUpTheWindowAlpha() {
        #expect(ChromePalette.frameUnderGlassAlpha(windowOpacity: 1) == 1)
        // Frame and glass together hide as much as a pane: 1 - (1 - a)(1 - g) == opacity.
        for opacity in [0.97, 0.9, 0.8] {
            let a = ChromePalette.frameUnderGlassAlpha(windowOpacity: opacity, glass: 0.7)
            #expect(abs(1 - (1 - a) * 0.3 - opacity) < 1e-9)
        }
        #expect(ChromePalette.frameUnderGlassAlpha(windowOpacity: 0.5, glass: 0.7) == 0, "the glass shows alone")
    }

    @Test func aGroundTakesTheWindowOpacityAsItsAlpha() {
        let palette = ChromePalette()
        let ground = LoamTheme.ground(LoamTheme.surface("frame", night: 0x12110f, day: 0xeeeae2, palette: palette), palette: palette)
        func alpha(_ name: NSAppearance.Name) -> CGFloat {
            var result: CGFloat = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = ground.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }
            return result
        }
        #expect(alpha(.darkAqua) == 1)
        palette.follow(windowOpacity: 0.8)
        #expect(abs(alpha(.darkAqua) - 0.8) < 0.001)
        #expect(resolved(ground, .darkAqua) == 0x12110f, "the color keeps its value")
        #expect(resolved(ground, .aqua) == 0xeeeae2, "the color follows the appearance")
    }

    @Test func theChromeGroundIsHorizonAInNightAndHorizonOInDay() {
        let palette = ChromePalette()
        let chrome = LoamTheme.chrome(palette: palette)
        #expect(resolved(chrome, .darkAqua) == 0x211e1a)
        #expect(resolved(chrome, .aqua) == 0xeeeae2)
        palette.follow(terminalBackground: 0x1e1e2e)
        let derived = ChromeSurfaces.derive(background: 0x1e1e2e)
        #expect(resolved(chrome, .darkAqua) == derived.horizonA, "it follows the terminal theme")
    }

    private final class Counter: @unchecked Sendable { var value = 0 }

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = LoamTheme.hex(color) ?? 0
        }
        return result
    }
}

/// Ticket 68: the window subtitle names the main repo and its branch.
@Suite struct RepoLineTests {
    private func reader(_ files: [String: String]) -> (String) -> String? { { files[$0] } }

    @Test func aBranch() {
        let line = RepoLine(path: "/src/loam", read: reader(["/src/loam/.git/HEAD": "ref: refs/heads/main\n"]))
        #expect(line == RepoLine(path: "/src/loam", read: reader(["/src/loam/.git/HEAD": "ref: refs/heads/main"])))
        #expect(line.text == "loam \u{00B7} main")
    }

    @Test func aBranchWithASlash() {
        let line = RepoLine(path: "/src/loam", read: reader(["/src/loam/.git/HEAD": "ref: refs/heads/me/test\n"]))
        #expect(line.branch == "me/test")
    }

    @Test func aDetachedHeadShowsTheShortCommit() {
        let line = RepoLine(path: "/src/loam", read: reader(["/src/loam/.git/HEAD": "34c6ada5f00d\n"]))
        #expect(line.text == "loam \u{00B7} 34c6ada")
    }

    @Test func aWorktreeFollowsItsGitdir() {
        let line = RepoLine(path: "/wt/loam-x", read: reader([
            "/wt/loam-x/.git": "gitdir: /src/loam/.git/worktrees/loam-x\n",
            "/src/loam/.git/worktrees/loam-x/HEAD": "ref: refs/heads/feature\n",
        ]))
        #expect(line.text == "loam-x \u{00B7} feature")
    }

    @Test func aFolderThatIsNotARepoShowsTheNameOnly() {
        #expect(RepoLine(path: "/src/notes", read: reader([:])).text == "notes")
    }
}

/// Ticket 69: the subtitle follows a checkout.
@Suite struct HeadWatcherTests {
    @Test func gitDirectoryOfARepoIsDotGit() {
        #expect(RepoLine.gitDirectory(path: "/src/loam", read: { _ in nil }).path == "/src/loam/.git")
    }

    @Test func gitDirectoryOfAWorktreeIsTheNamedFolder() {
        let dir = RepoLine.gitDirectory(path: "/wt/x", read: { $0 == "/wt/x/.git" ? "gitdir: /src/loam/.git/worktrees/x\n" : nil })
        #expect(dir.path == "/src/loam/.git/worktrees/x")
    }

    @MainActor @Test func aCheckoutCallsOnChange() async throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("headwatcher-\(UUID().uuidString)")
        let git = repo.appendingPathComponent(".git")
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        var changes = 0
        let watcher = HeadWatcher { changes += 1 }
        watcher.watch(repo: repo.path)
        // Git writes HEAD.lock and renames it over HEAD. An atomic write does the same.
        var wrote = 0
        while changes == 0 && wrote < 100 {
            try await Task.sleep(for: .milliseconds(50))
            try "ref: refs/heads/other\(wrote)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
            wrote += 1
        }
        #expect(changes > 0)
        #expect(RepoLine(path: repo.path).branch == "other\(wrote - 1)")
        watcher.stop()
    }

    @MainActor @Test func stoppedWatcherSaysNothing() async throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("headwatcher-\(UUID().uuidString)")
        let git = repo.appendingPathComponent(".git")
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        var changes = 0
        let watcher = HeadWatcher { changes += 1 }
        watcher.watch(repo: repo.path)
        watcher.stop()
        try await Task.sleep(for: .milliseconds(200))
        try "ref: refs/heads/x\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes == 0)
    }
}
