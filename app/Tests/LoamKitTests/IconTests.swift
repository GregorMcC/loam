import AppKit
import Testing
@testable import LoamKit

@Suite struct IconTests {
    @Test func aLinkTakesTheIconOfItsKind() {
        #expect(LoamIcon.link(.github, target: "https://github.com/a/b") == .brand(.github))
        #expect(LoamIcon.link(.linear, target: "https://linear.app/t/issue/X-1") == .brand(.linear))
        // Notion and Obsidian marks are not free to use, so their links take SF Symbols.
        #expect(LoamIcon.link(.notion, target: "https://www.notion.so/x") == .symbol("doc.richtext"))
        #expect(LoamIcon.link(.vault, target: "obsidian://open?file=x") == .symbol("doc.text"))
        #expect(LoamIcon.link(.url, target: "https://example.test") == .symbol("link"))
        #expect(LoamIcon.link(.path, target: "/Users/me/code") == .symbol("folder"))
        #expect(LoamIcon.link(.path, target: "/Users/me/spec.md") == .symbol("doc"))
    }

    @Test func aClaudeURLTakesTheClaudeMark() {
        #expect(LoamIcon.link(.url, target: "https://claude.ai/chat/1") == .brand(.claude))
        #expect(LoamIcon.link(.url, target: "https://notclaude.ai/x") == .symbol("link"))
    }

    @Test func aSessionPaneTakesTheClaudeMarkAndAShellTakesTerminal() {
        #expect(LoamIcon.pane(.session) == .brand(.claude))
        #expect(LoamIcon.pane(.shell) == .symbol("terminal"))
    }

    @MainActor @Test(arguments: BrandMark.allCases)
    func eachMarkDrawsAsATemplateImage(_ mark: BrandMark) throws {
        let image = mark.image
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 24, height: 24))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<24 { for y in 0..<24 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        // Each mark covers a fair part of its square, and none fills it.
        #expect(inked > 24 * 24 / 10)
        #expect(inked < 24 * 24 * 9 / 10)
    }
}
