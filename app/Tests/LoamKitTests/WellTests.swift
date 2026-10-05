import AppKit
import Testing
@testable import LoamKit

/// Ticket 88: the inset terminal well, and the hairlines and fills mixed from the ink.
@Suite struct WellTests {
    @Test func theWellHasAMarginWhereNoRegionTouchesIt() {
        let both = WellLayout.insets(sidebarShown: true, panelShown: true)
        #expect(both == WellLayout.Insets(top: 8, left: 0, bottom: WellLayout.bottomMargin, right: 0))
        let none = WellLayout.insets(sidebarShown: false, panelShown: false)
        #expect(none == WellLayout.Insets(top: 8, left: 8, bottom: WellLayout.bottomMargin, right: 8))
        #expect(WellLayout.insets(sidebarShown: true, panelShown: false).right == 8)
        #expect(WellLayout.insets(sidebarShown: false, panelShown: true).left == 8)
    }

    @Test func theBottomMarginIsOnePlaceThatAnotherRowCanTake() {
        #expect(WellLayout.insets(sidebarShown: true, panelShown: true, bottom: 40).bottom == 40)
    }

    private func resolve(_ color: NSColor, dark: Bool) -> NSColor {
        var out = color
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)!
        }
        return out
    }

    @Test func theHairlineIsTheInkAtEightPercent() {
        let palette = ChromePalette()
        for dark in [true, false] {
            let line = resolve(LoamTheme.inkAlpha(LoamTheme.hairlineAlpha, palette: palette), dark: dark)
            let ink = resolve(LoamTheme.ink, dark: dark)
            #expect(abs(line.alphaComponent - 0.08) < 0.001)
            #expect(LoamTheme.hex(line) == LoamTheme.hex(ink))
        }
    }

    @Test func theInkFollowsTheTerminalTheme() {
        let palette = ChromePalette()
        palette.follow(terminalBackground: 0x1e1e2e)
        let line = resolve(LoamTheme.inkAlpha(0.09, palette: palette), dark: true)
        #expect(LoamTheme.hex(line) == ChromeSurfaces.derive(background: 0x1e1e2e).ink)
    }

    /// The solid hairline is the ink at 8% over bedrock, so a divider in a split matches the well edge.
    @Test func theSolidHairlineIsTheInkMixedIntoBedrock() {
        let palette = ChromePalette()
        let mixed = resolve(LoamTheme.inkOver(LoamTheme.srgb(0x12110f), alpha: 0.08, palette: palette), dark: true)
        #expect(mixed.alphaComponent == 1)
        // 0x12 + 0.08 * (0xed - 0x12) = 35.5
        #expect(abs(mixed.redComponent * 255 - 35.5) < 0.6)
    }
}
