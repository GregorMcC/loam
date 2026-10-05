import AppKit
import Foundation
import Testing
@testable import LoamKit

@Suite(.serialized) @MainActor struct LoamMotionTests {
    @Test func haloRunsThreeCyclesOnArrival() {
        #expect(LoamMotion.haloCycles(arriving: true, paneFocused: false, reduceMotion: false) == 3)
    }

    @Test func haloNeverRunsWhileThePaneHasFocus() {
        #expect(LoamMotion.haloCycles(arriving: true, paneFocused: true, reduceMotion: false) == 0)
    }

    @Test func reduceMotionDropsTheHalo() {
        #expect(LoamMotion.haloCycles(arriving: true, paneFocused: false, reduceMotion: true) == 0)
    }

    @Test func noArrivalMeansNoHalo() {
        #expect(LoamMotion.haloCycles(arriving: false, paneFocused: false, reduceMotion: false) == 0)
    }

    @Test func theDotPlaysTheHaloThreeTimesAtTheTokenDuration() throws {
        LoamMotion.reduceMotionOverride = false
        defer { LoamMotion.reduceMotionOverride = nil }
        let dot = AttentionDotView(frame: .zero)
        dot.mark = .needs
        dot.isArriving = true
        let animation = try #require(dot.haloAnimation)
        #expect(animation.duration == LoamTheme.durationHalo)
        #expect(animation.repeatCount == 3)
        // The cycles end. The animation does not repeat forever.
        #expect(animation.repeatCount != .infinity)
    }

    @Test func focusStopsTheHalo() {
        LoamMotion.reduceMotionOverride = false
        defer { LoamMotion.reduceMotionOverride = nil }
        let dot = AttentionDotView(frame: .zero)
        dot.mark = .needs
        dot.isArriving = true
        #expect(dot.isHaloRunning)
        dot.paneFocused = true
        #expect(!dot.isHaloRunning)
    }

    @Test func reduceMotionStopsTheHalo() {
        LoamMotion.reduceMotionOverride = true
        defer { LoamMotion.reduceMotionOverride = nil }
        let dot = AttentionDotView(frame: .zero)
        dot.mark = .needs
        dot.isArriving = true
        #expect(!dot.isHaloRunning)
    }

    @Test func onlyNeedsYouHasAHalo() {
        LoamMotion.reduceMotionOverride = false
        defer { LoamMotion.reduceMotionOverride = nil }
        for mark in [AttentionMark.active, .idle, .unread] {
            let dot = AttentionDotView(frame: .zero)
            dot.mark = mark
            dot.isArriving = true
            #expect(!dot.isHaloRunning, "\(mark)")
        }
    }

    @Test func theDotSizeIsEightPoints() {
        #expect(AttentionDotView(frame: .zero).intrinsicContentSize == NSSize(width: 8, height: 8))
    }
}

@Suite struct TerminalThemeDefaultsTests {
    @Test func theDefaultsFileHoldsOnlyAThemeLine() {
        let text = TerminalThemeDefaults.fileText(themesFolder: "/x/themes")
        #expect(text == "theme = dark:/x/themes/loam-night,light:/x/themes/loam-day\n")
        #expect(!text.contains("background"))
    }

    @Test func theSourceTreeHoldsBothThemes() throws {
        let folder = try #require(TerminalThemeDefaults.themesFolder())
        #expect(FileManager.default.fileExists(atPath: folder + "/loam-night"))
        #expect(FileManager.default.fileExists(atPath: folder + "/loam-day"))
    }

    @Test func writesTheDefaultsFileAndRewritesOnAChange() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("loam-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let path = try #require(TerminalThemeDefaults.writeDefaultsFile(themesFolder: "/a", cacheFolder: cache))
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("dark:/a/loam-night"))
        _ = TerminalThemeDefaults.writeDefaultsFile(themesFolder: "/b", cacheFolder: cache)
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("dark:/b/loam-night"))
    }

    @Test func noThemesMeansNoFile() {
        #expect(TerminalThemeDefaults.writeDefaultsFile(themesFolder: nil) == nil)
    }
}
