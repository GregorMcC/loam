import AppKit
import Foundation
import Testing

@testable import LoamKit

/// Ticket 120: the shadow tokens. `LoamTheme.shadow` mirrors `shadow-raised` and `shadow-switcher` of
/// `docs/design/tokens.json` by hand, so these tests read the CSS of each token and compare every layer. Before this
/// ticket the app drew one layer of each token, and Day lost its contact shadow.
@Suite struct ShadowTokenTests {
    /// The layers of a CSS `box-shadow`, such as "0 1px 0 #ffffff0d inset, 0 8px 24px #00000066".
    static func layers(_ css: String) -> [ShadowLayer] {
        css.split(separator: ",").compactMap { part in
            let words = part.split(separator: " ")
            let lengths = words.filter { $0.first?.isNumber == true || $0.first == "-" }
                .compactMap { Double($0.replacingOccurrences(of: "px", with: "")).map { CGFloat($0) } }
            guard lengths.count >= 2, let hex = words.first(where: { $0.hasPrefix("#") }), hex.count == 9,
                  let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return ShadowLayer(inset: words.contains("inset"), x: lengths[0], y: lengths[1],
                               blur: lengths.count > 2 ? lengths[2] : 0, spread: lengths.count > 3 ? lengths[3] : 0,
                               rgb: value >> 8, alpha: UInt8(value & 0xff))
        }
    }

    @Test func theJSONHasTheTwoTokens() {
        #expect(Set(LoamThemeTests.list("shadow").compactMap { $0["name"] as? String })
                == Set(LoamTheme.ShadowToken.allCases.map(\.rawValue)))
    }

    @Test(arguments: LoamTheme.ShadowToken.allCases)
    func eachLayerMatchesTheJSON(_ token: LoamTheme.ShadowToken) throws {
        let json = try #require(LoamThemeTests.list("shadow").first { $0["name"] as? String == token.rawValue })
        let value = try #require(json["value"] as? [String: String])
        let night = Self.layers(value["night"] ?? ""), day = Self.layers(value["day"] ?? "")
        #expect(!night.isEmpty && !day.isEmpty, "\(token.rawValue) has no layers")
        #expect(LoamTheme.shadow(token, dark: true) == night, "\(token.rawValue) night")
        #expect(LoamTheme.shadow(token, dark: false) == day, "\(token.rawValue) day")
    }

    @Test func theParserReadsEachPartOfALayer() {
        #expect(Self.layers("0 1px 0 #ffffff0d inset, 0 0 0 1px #00000052, 2px 8px 24px #2a201424") == [
            ShadowLayer(inset: true, y: 1, blur: 0, rgb: 0xffffff, alpha: 0x0d),
            ShadowLayer(y: 0, blur: 0, spread: 1, rgb: 0x000000, alpha: 0x52),
            ShadowLayer(x: 2, y: 8, blur: 24, rgb: 0x2a2014, alpha: 0x24),
        ])
    }

    @Test func aLayerGivesTheRadiusAndTheColourThatSwiftUITakes() throws {
        let layer = ShadowLayer(y: 8, blur: 24, rgb: 0x2a2014, alpha: 0x24)
        // Core Animation and SwiftUI blur by a radius that is half the CSS blur.
        #expect(layer.radius == 12)
        let color = try #require(layer.color.usingColorSpace(.sRGB))
        #expect(abs(color.alphaComponent - 0x24 / 255) < 0.001)
        #expect(abs(color.redComponent - 0x2a / 255) < 0.001 && abs(color.blueComponent - 0x14 / 255) < 0.001)
    }
}
