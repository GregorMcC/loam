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

/// Ticket 109: the pane header names the branch and then the PR number. The number is never cut.
@Suite struct PaneHeaderLayoutTests {
    @Test func everyLabelKeepsItsWidthWhenThereIsRoom() {
        let widths = PaneHeaderLayout.widths(title: 60, branch: 80, number: 24, room: 400)
        #expect(widths == PaneHeaderLayout.Widths(title: 60, branch: 80, number: 24))
    }

    @Test func aLongBranchIsCutAndTheNumberKeepsItsWidth() {
        let room: CGFloat = 200
        let widths = PaneHeaderLayout.widths(title: 60, branch: 300, number: 24, room: room)
        #expect(widths.title == 60 && widths.number == 24)
        #expect(widths.branch == room - 60 - PaneHeaderLayout.gap - 24 - PaneHeaderLayout.numberGap)
    }

    @Test func aLongTitleLeavesRoomForTheNumber() {
        let widths = PaneHeaderLayout.widths(title: 500, branch: 80, number: 24, room: 200)
        #expect(widths.number == 24 && widths.branch == 0)
        #expect(widths.title == 200 - PaneHeaderLayout.gap - 24 - PaneHeaderLayout.numberGap)
    }

    @Test func theNumberNeverEndsPastTheRoom() {
        let number: CGFloat = 24
        let least = PaneHeaderLayout.gap + number + PaneHeaderLayout.numberGap
        for room in stride(from: least, through: 600, by: 7) {
            for title in [0, 40, 168, 500] as [CGFloat] {
                for branch in [0, 80, 300] as [CGFloat] {
                    let widths = PaneHeaderLayout.widths(title: title, branch: branch, number: number, room: room)
                    let end = widths.title + PaneHeaderLayout.gap + widths.branch + PaneHeaderLayout.numberGap + widths.number
                    #expect(end <= room, "title \(title), branch \(branch), room \(room): the number ends at \(end)")
                    #expect(widths.number == number)
                }
            }
        }
    }

    @Test func aWorktreeWithNoPRGivesTheBranchTheRoomOfTheNumber() {
        let widths = PaneHeaderLayout.widths(title: 60, branch: 300, number: 0, room: 200)
        #expect(widths.number == 0 && widths.branch == 200 - 60 - PaneHeaderLayout.gap)
    }
}
