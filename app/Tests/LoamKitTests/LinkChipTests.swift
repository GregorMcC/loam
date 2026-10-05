import Testing
@testable import LoamKit

@Suite struct LinkChipTests {
    private func link(_ kind: LinkKind, _ target: String) -> PlotLink {
        PlotLink(id: "l", label: "x", target: target, note: "", position: 0, version: 1, kind: kind, exists: nil)
    }

    @Test func namesTheKind() {
        #expect(link(.github, "https://github.com/x").chipName == "GitHub")
        #expect(link(.notion, "https://notion.so/x").chipName == "Notion")
        #expect(link(.linear, "https://linear.app/x").chipName == "Linear")
        #expect(link(.vault, "/v/Note.md").chipName == "Vault")
        #expect(link(.path, "/a/b").chipName == "Folder")
        #expect(link(.path, "/a/b.txt").chipName == "File")
        #expect(link(.url, "https://x").chipName == "URL")
    }
}
