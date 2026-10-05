import Foundation
import Testing
@testable import LoamKit

@MainActor
@Suite struct PlotPanelModelTests {
    private func model(_ outputs: [(fixture: String, exit: Int32)]) throws -> (PlotPanelModel, FakeLoam) {
        let fake = try FakeLoam(outputs)
        return (PlotPanelModel(client: fake.client()), fake)
    }

    @Test func loadShowsThePlot() async throws {
        let (m, fake) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        #expect(m.plot?.id == "plotaaaaab")
        #expect(m.plot?.links.count == 8)
        #expect(fake.args() == ["show plotaaaaab --json"])
    }

    @Test func aRequestWaitsForItsPlot() async throws {
        let (m, _) = try model([("show_links", 0)])
        m.request = .addLink
        m.requestPlot = "plotaaaaab"
        #expect(m.readyRequest == nil, "no plot has loaded")
        await m.load(plotID: "plotaaaaab")
        #expect(m.readyRequest == .addLink)
        m.requestPlot = "another"
        #expect(m.readyRequest == nil, "the panel still shows the last plot")
    }

    @Test func editThenSaveUsesExpectAndActor() async throws {
        let (m, fake) = try model([("show_links", 0), ("set", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.whereItStands, to: "Panel done")
        #expect(m.isDirty(.whereItStands))
        await m.save(.whereItStands)
        #expect(fake.args().last == "set plotaaaaab where-it-stands - --expect where=4 --json --actor app")
        #expect(!m.isDirty(.whereItStands))
        #expect(m.clash == nil)
        let stdin = try String(contentsOf: fake.stdinLog, encoding: .utf8)
        #expect(stdin == "Panel done")
    }

    @Test func saveWithoutChangeWritesNothing() async throws {
        let (m, fake) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: m.text(of: .what))
        await m.save(.what)
        #expect(fake.args().count == 1)
    }

    @Test func staleWriteShowsTheClashWithTheCurrentValue() async throws {
        let (m, fake) = try model([("show_links", 0), ("error_stale", 10), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: "My text")
        await m.save(.what)
        let clash = try #require(m.clash)
        #expect(clash.item == "what")
        #expect(clash.yours == "My text")
        #expect(clash.current != nil)
        // The draft stays, so nothing the person typed is lost.
        #expect(m.shownText(of: .what) == "My text")
        #expect(fake.args()[1].contains("--expect what=17"))
    }

    @Test func keepMineWritesAgainWithTheNewVersion() async throws {
        let (m, fake) = try model([("show_links", 0), ("error_stale", 10), ("show_links", 0), ("show_links", 0), ("set", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: "My text")
        await m.save(.what)
        await m.keepMine()
        #expect(m.clash == nil)
        #expect(fake.args().last?.hasPrefix("set plotaaaaab what - --expect what=17") == true)
        #expect(!m.isDirty(.what))
    }

    @Test func useCurrentDropsTheDraft() async throws {
        let (m, _) = try model([("show_links", 0), ("error_stale", 10), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: "My text")
        await m.save(.what)
        await m.useCurrent()
        #expect(m.clash == nil)
        #expect(m.shownText(of: .what) == m.text(of: .what))
    }

    @Test func draftKeepsItsBaseVersionAcrossAReload() async throws {
        // The draft began at version 17. A reload must not move the base.
        let (m, _) = try model([("show_links", 0), ("show", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: "Draft")
        await m.load(plotID: "plotaaaaab")
        #expect(m.drafts[.what]?.base == 17)
        #expect(m.shownText(of: .what) == "Draft")
    }

    @Test func noPlotClearsTheDrafts() async throws {
        let (m, _) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.what, to: "Draft")
        await m.load(plotID: nil)
        #expect(m.plot == nil)
        #expect(m.drafts.isEmpty)
    }

    @Test func briefWarningAppearsOverThreeHundredWords() async throws {
        let (m, _) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.why, to: String(repeating: "word ", count: 150))
        m.edit(.whereItStands, to: String(repeating: "word ", count: 150))
        let base = PlotPanelModel.wordCount(m.text(of: .what))
        #expect(m.briefWordCount == 300 + base)
        #expect((m.briefWarning != nil) == (300 + base > PlotPanelModel.briefWordLimit))
        m.edit(.why, to: String(repeating: "word ", count: 160))
        #expect(m.briefWarning != nil)
        m.edit(.why, to: "short")
        m.edit(.whereItStands, to: "short")
        #expect(m.briefWarning == nil)
    }

    @Test func wordCountSplitsOnWhitespace() {
        #expect(PlotPanelModel.wordCount("") == 0)
        #expect(PlotPanelModel.wordCount("  one\ntwo   three ") == 3)
    }

    @Test func missingLocalLinkIsMarked() async throws {
        let (m, _) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        let links = try #require(m.plot?.links)
        #expect(links.filter(m.isMissing).map(\.id) == ["linkaaaaai"])
    }

    @Test func openCallsLoamOpen() async throws {
        let (m, fake) = try model([("show_links", 0), ("open_vault", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.open(linkID: "linkaaaaah")
        #expect(fake.args().last == "open plotaaaaab linkaaaaah --json --actor app")
        #expect(m.missingLink == nil)
    }

    @Test func openMissingPathShowsTheMessage() async throws {
        let (m, _) = try model([("show_links", 0), ("error_link_path_missing", 12), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.open(linkID: "linkaaaaai")
        #expect(m.missingLink == MissingLink(linkID: "linkaaaaai", path: "/tmp/loam-contract/vault/missing.md"))
        m.dismissMissingLink()
        #expect(m.missingLink == nil)
    }

    /// Ticket 57: a slow open that ends after a newer open must not clear the missing link box.
    @Test func slowOpenDoesNotClearTheMissingLinkOfALaterOpen() async throws {
        let (m, fake) = try model([("show_links", 0)])
        let dir = Fixtures.dir.path
        try """
        #!/bin/sh
        case "$*" in
        *linkaaaaah*) sleep 1; cat '\(dir)/open_vault.json';;
        *linkaaaaai*) cat '\(dir)/error_link_path_missing.json'; exit 12;;
        *) cat '\(dir)/show_links.json';;
        esac
        """.write(to: fake.script, atomically: true, encoding: .utf8)
        await m.load(plotID: "plotaaaaab")
        let slow = Task { await m.open(linkID: "linkaaaaah") }
        try await Task.sleep(for: .milliseconds(200))
        await m.open(linkID: "linkaaaaai")
        #expect(m.missingLink?.linkID == "linkaaaaai")
        await slow.value
        #expect(m.missingLink?.linkID == "linkaaaaai")
    }

    @Test func addLinkSendsLabelAndTarget() async throws {
        let (m, fake) = try model([("show_links", 0), ("link_add_app", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addLink(label: "Spec", target: "https://example.com/spec")
        #expect(fake.args()[1] == "link add plotaaaaab Spec https://example.com/spec --json --actor app")
    }

    @Test func addLinkNeedsATarget() async throws {
        let (m, fake) = try model([("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addLink(label: "Spec", target: " ")
        #expect(m.errorMessage != nil)
        #expect(fake.args().count == 1)
    }

    // Ticket 78: with no label, the core takes one from the target.
    @Test func addLinkWithNoLabelLeavesTheLabelOut() async throws {
        let (m, fake) = try model([("show_links", 0), ("link_add_app", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addLink(label: " ", target: "https://example.com/spec")
        #expect(fake.args()[1] == "link add plotaaaaab https://example.com/spec --json --actor app")
    }

    // Ticket 78: the add repo row offers the repos of other plots and the checkouts next to them, and
    // Return on a name adds the first suggestion.
    @Test func repoSuggestionsAndReturnOnAName() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suggest-\(UUID().uuidString)")
        for name in ["alpha", "notes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alpha/.git"), withIntermediateDirectories: true)
        let alpha = AddSources.standard(root.appendingPathComponent("alpha").path)
        let (m, fake) = try model([("show_links", 0), ("export", 0)])
        m.suggestionRoots = [root.path]
        await m.load(plotID: "plotaaaaab")
        await m.loadRepoSuggestions()
        #expect(fake.args()[1] == "export --json")
        #expect(m.repoCandidates.map(\.path) == ["/tmp/loam-contract/repos/docs", alpha])
        // The plot holds docs already, so only alpha shows.
        #expect(m.repoSuggestions(matching: "").map(\.path) == [alpha])
        #expect(m.repoPath(forInput: " alp ") == alpha)
        #expect(m.repoPath(forInput: "/some/path") == "/some/path")
        #expect(m.repoPath(forInput: "nothing") == "nothing")
    }

    // Ticket 78: a dropped checkout becomes a repo, and a dropped URL a link with no label.
    @Test func addDroppedRoutesEachItem() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let (m, fake) = try model([("show_links", 0), ("repo_add", 0), ("show_links", 0), ("link_add_app", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addDropped([repo, URL(string: "https://example.com/doc")!])
        #expect(fake.args()[1] == "repo add plotaaaaab \(AddSources.standard(repo.path)) --json --actor app")
        #expect(fake.args()[3] == "link add plotaaaaab https://example.com/doc --json --actor app")
    }

    // Ticket 91: a repo add that left the checkout on its branch says why. The next add clears it.
    @Test func addRepoShowsTheWarnings() async throws {
        let (m, _) = try model([("show_links", 0), ("repo_add_dirty", 0), ("show_links", 0), ("repo_add", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addRepo(path: "/tmp/loam-contract/repos/dirty")
        #expect(m.notice == "dirty has uncommitted changes, so Loam left it on main.")
        #expect(m.errorMessage == nil)
        await m.addRepo(path: "/tmp/loam-contract/repos/app")
        #expect(m.notice == nil)
    }

    @Test func addDroppedStopsAtTheFirstError() async throws {
        let (m, fake) = try model([("show_links", 0), ("error_invalid", 2), ("link_add_app", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.addDropped([URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!])
        #expect(m.errorMessage != nil)
        #expect(fake.args().count == 2)
    }

    @Test func editLinkExpectsTheLinkVersion() async throws {
        let (m, fake) = try model([("show_links", 0), ("link_edit", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.editLink(id: "linkaaaaai", label: "Missing", target: "/new/path", note: "")
        #expect(fake.args()[1].contains("--expect link:linkaaaaai=23"))
        #expect(fake.args()[1].contains("--target /new/path"))
    }

    @Test func removeLinkExpectsTheLinkVersion() async throws {
        let (m, fake) = try model([("show_links", 0), ("link_rm", 0), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.removeLink(id: "linkaaaaab")
        #expect(fake.args()[1] == "link rm plotaaaaab linkaaaaab --expect link:linkaaaaab=7 --json --actor app")
    }

    @Test func staleLinkEditShowsClash() async throws {
        let (m, _) = try model([("show_links", 0), ("error_stale", 10), ("show_links", 0)])
        await m.load(plotID: "plotaaaaab")
        await m.editLink(id: "linkaaaaab", label: "A", target: "https://a.example", note: "")
        let clash = try #require(m.clash)
        #expect(clash.pending == .linkEdit(id: "linkaaaaab", label: "A", target: "https://a.example", note: ""))
        #expect(clash.yours == "A: https://a.example")
    }

    @Test func otherErrorsShowAsAMessage() async throws {
        let (m, _) = try model([("show_links", 0), ("error_generic", 1)])
        await m.load(plotID: "plotaaaaab")
        m.edit(.why, to: "x")
        await m.save(.why)
        #expect(m.clash == nil)
        #expect(m.errorMessage != nil)
        #expect(m.isDirty(.why))
    }
}
