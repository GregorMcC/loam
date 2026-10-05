import AppKit
import Foundation
import Testing
@testable import LoamKit

/// The theme test (ticket 55). `LoamTheme.swift` and the Ghostty themes come from
/// `docs/design/tokens.json` by `scripts/gen-loam-theme.py`. These tests fail when
/// a file and the JSON disagree. Run the script to fix it.
@Suite struct LoamThemeTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    nonisolated(unsafe) static let tokens: [String: Any] = {
        let data = try! Data(contentsOf: root.appendingPathComponent("docs/design/tokens.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    static func list(_ group: String) -> [[String: Any]] {
        (tokens[group] as! [String: Any])["tokens"] as! [[String: Any]]
    }

    static func hex(_ text: String) -> UInt32 { UInt32(text.dropFirst(), radix: 16)! }
    static func number(_ text: Any, suffix: String) -> Double {
        Double((text as! String).dropLast(suffix.count))!
    }

    @Test func everyColorTokenMatchesTheJSON() {
        let json = Self.list("color")
        #expect(json.count == LoamTheme.colorTokens.count)
        for (token, swift) in zip(json, LoamTheme.colorTokens) {
            let value = token["value"] as! [String: String]
            #expect(swift.name == token["name"] as? String)
            #expect(swift.night == Self.hex(value["night"]!), "\(swift.name) night")
            #expect(swift.day == Self.hex(value["day"]!), "\(swift.name) day")
        }
    }

    @Test func aDynamicColorResolvesPerAppearance() throws {
        for token in LoamTheme.colorTokens {
            let color = try #require(namedColor(token.name))
            #expect(resolved(color, .darkAqua) == token.night, "\(token.name) night")
            #expect(resolved(color, .aqua) == token.day, "\(token.name) day")
        }
    }

    /// The static property for a token name, as the app reads it.
    private func namedColor(_ name: String) -> NSColor? {
        let all: [String: NSColor] = [
            "bedrock": LoamTheme.bedrock, "horizon-o": LoamTheme.horizonO, "horizon-a": LoamTheme.horizonA,
            "horizon-b": LoamTheme.horizonB, "rule": LoamTheme.rule, "frame": LoamTheme.frame, "edge": LoamTheme.edge, "ink": LoamTheme.ink,
            "ink-muted": LoamTheme.inkMuted, "ink-faint": LoamTheme.inkFaint, "moss": LoamTheme.moss,
            "on-moss": LoamTheme.onMoss, "moss-wash": LoamTheme.mossWash, "needs-you": LoamTheme.needsYou,
            "needs-you-wash": LoamTheme.needsYouWash, "done-unread": LoamTheme.doneUnread,
            "done-unread-wash": LoamTheme.doneUnreadWash, "rust": LoamTheme.rust, "rust-wash": LoamTheme.rustWash,
            "focus": LoamTheme.focus, "selection": LoamTheme.selection, "cursor": LoamTheme.cursor,
            "ansi-black": LoamTheme.ansiBlack, "ansi-red": LoamTheme.ansiRed, "ansi-green": LoamTheme.ansiGreen,
            "ansi-yellow": LoamTheme.ansiYellow, "ansi-blue": LoamTheme.ansiBlue,
            "ansi-magenta": LoamTheme.ansiMagenta, "ansi-cyan": LoamTheme.ansiCyan, "ansi-white": LoamTheme.ansiWhite,
            "ansi-bright-black": LoamTheme.ansiBrightBlack, "ansi-bright-red": LoamTheme.ansiBrightRed,
            "ansi-bright-green": LoamTheme.ansiBrightGreen, "ansi-bright-yellow": LoamTheme.ansiBrightYellow,
            "ansi-bright-blue": LoamTheme.ansiBrightBlue, "ansi-bright-magenta": LoamTheme.ansiBrightMagenta,
            "ansi-bright-cyan": LoamTheme.ansiBrightCyan, "ansi-bright-white": LoamTheme.ansiBrightWhite,
        ]
        return all[name]
    }

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
            result = byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent)
        }
        return result
    }

    @Test func everyColorTokenHasAProperty() {
        for token in LoamTheme.colorTokens { #expect(namedColor(token.name) != nil, "\(token.name)") }
    }

    @Test func spacingRadiusAndDurationMatchTheJSON() {
        for token in Self.list("spacing") {
            #expect(LoamTheme.spacing[token["name"] as! String] == CGFloat(Self.number(token["value"]!, suffix: "px")))
        }
        #expect(LoamTheme.spacing.count == Self.list("spacing").count)
        for token in Self.list("radius") {
            #expect(LoamTheme.radii[token["name"] as! String] == CGFloat(Self.number(token["value"]!, suffix: "px")))
        }
        #expect(LoamTheme.radii.count == Self.list("radius").count)
        for token in Self.list("duration") {
            let seconds = Self.number(token["value"]!, suffix: "ms") / 1000
            #expect(LoamTheme.durations[token["name"] as! String] == seconds)
        }
        #expect(LoamTheme.durations.count == Self.list("duration").count)
        #expect(LoamTheme.space3 == 12)
        #expect(LoamTheme.radiusSm == 6)
        #expect(LoamTheme.durationHalo == 1.6)
    }

    @Test func easingsMatchTheJSON() {
        for token in Self.list("easing") {
            let value = (token["value"] as! String).dropFirst("cubic-bezier(".count).dropLast()
            let points = value.split(separator: ",").map { Float($0.trimmingCharacters(in: .whitespaces))! }
            let easing = LoamTheme.easings[token["name"] as! String]
            #expect([easing?.x1, easing?.y1, easing?.x2, easing?.y2] == points.map { Optional($0) })
        }
        #expect(LoamTheme.easings.count == Self.list("easing").count)
    }

    @Test func typeStylesMatchTheJSON() {
        let type = Self.tokens["type"] as! [String: Any]
        var json: [(String, String, [String: Any])] = []
        for group in type["groups"] as! [[String: Any]] {
            for style in group["styles"] as! [[String: Any]] {
                json.append((style["name"] as! String, group["family"] as! String, style))
            }
        }
        #expect(json.count == LoamTheme.typeStyles.count)
        for (name, family, style) in json {
            let swift = LoamTheme.typeStyles.first { $0.name == name }
            #expect(swift?.family == family, "\(name)")
            #expect(swift?.size == CGFloat(Self.number(style["fontSize"]!, suffix: "px")), "\(name) size")
            #expect(swift?.lineHeight == CGFloat(Self.number(style["lineHeight"]!, suffix: "px")), "\(name) line")
            #expect(swift?.weight == style["fontWeight"] as? Int, "\(name) weight")
            let tracking = (style["letterSpacing"] as? String).map { Self.number($0, suffix: "em") } ?? 0
            #expect(swift?.tracking == CGFloat(tracking), "\(name) tracking")
        }
    }

    // MARK: Ghostty themes

    private func themeLines(_ name: String) throws -> [String: [String]] {
        let url = Self.root.appendingPathComponent("app/Resources/ghostty-themes/\(name)")
        var lines: [String: [String]] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            lines[parts[0], default: []].append(parts[1])
        }
        return lines
    }

    @Test(arguments: [("loam-night", true), ("loam-day", false)])
    func theGhosttyThemeMatchesTheTokens(name: String, night: Bool) throws {
        let lines = try themeLines(name)
        func color(_ token: String) -> String {
            let found = LoamTheme.colorTokens.first { $0.name == token }!
            return String(format: "#%06x", night ? found.night : found.day)
        }
        #expect(lines["background"] == [color("bedrock")])
        #expect(lines["foreground"] == [color("ink")])
        #expect(lines["cursor-color"] == [color("cursor")])
        #expect(lines["selection-background"] == [color("selection")])
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var palette: [String] = []
        for (i, n) in names.enumerated() { palette.append("\(i)=\(color("ansi-" + n))") }
        for (i, n) in names.enumerated() { palette.append("\(i + 8)=\(color("ansi-bright-" + n))") }
        #expect(lines["palette"] == palette)
    }
}
