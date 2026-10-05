import Foundation
import Testing
@testable import LoamKit

/// Ticket 78: repo suggestions and drops on the plot panel.
@Suite struct AddSourcesTests {
    /// A temp folder with the given subfolders. A name in `checkouts` gets a `.git` folder.
    private func folder(_ names: [String], checkouts: Set<String>) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("add-sources-\(UUID().uuidString)")
        for name in names {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if checkouts.contains(name) {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            }
        }
        return AddSources.standard(root.path)
    }

    @Test func scanFindsKnownReposThenCheckoutsNextToThemAndInTheRoots() throws {
        let dev = try folder(["loam", "recipes", "notes", ".hidden"], checkouts: ["loam", "recipes", ".hidden"])
        let other = try folder(["work-app"], checkouts: ["work-app"])
        let all = AddSources.scan(known: ["\(dev)/loam", "\(dev)/loam/"], roots: [other, "/no/such/folder"])
        #expect(all == [
            RepoSuggestion(path: "\(dev)/loam", known: true),
            RepoSuggestion(path: "\(dev)/recipes", known: false),
            RepoSuggestion(path: "\(other)/work-app", known: false),
        ])
    }

    @Test func matchingRanksKnownReposThenNamePrefixAndSkipsThePlotsRepos() {
        let all = [
            RepoSuggestion(path: "/d/my-loam", known: false),
            RepoSuggestion(path: "/d/loam-site", known: false),
            RepoSuggestion(path: "/d/old-loam", known: true),
            RepoSuggestion(path: "/d/loam", known: true),
            RepoSuggestion(path: "/d/recipes", known: false),
        ]
        #expect(AddSources.matching("LOAM", in: all, excluding: ["/d/loam"]).map(\.name) == ["old-loam", "loam-site", "my-loam"])
        #expect(AddSources.matching("", in: all).count == AddSources.suggestionLimit)
        #expect(AddSources.matching("  ", in: all, limit: 2).map(\.name) == ["old-loam", "loam"])
        #expect(AddSources.matching("zzz", in: all).isEmpty)
        // The path matches too.
        #expect(AddSources.matching("/d/rec", in: all).map(\.name) == ["recipes"])
    }

    @Test func isPath() {
        #expect(AddSources.isPath("/Users/me/x"))
        #expect(AddSources.isPath(" ~/x"))
        #expect(!AddSources.isPath("recipes"))
    }

    @Test func dropSendsACheckoutToReposAndTheRestToLinks() throws {
        let root = try folder(["repo", "plain"], checkouts: ["repo"])
        let file = "\(root)/plan.md"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(AddSources.dropped(URL(fileURLWithPath: "\(root)/repo")) == .repo("\(root)/repo"))
        #expect(AddSources.dropped(URL(fileURLWithPath: "\(root)/plain")) == .link("\(root)/plain"))
        #expect(AddSources.dropped(URL(fileURLWithPath: file)) == .link(file))
        #expect(AddSources.dropped(URL(fileURLWithPath: "\(root)/gone")) == nil)
        #expect(AddSources.dropped(URL(string: "https://github.com/me/app/pull/9")!) == .link("https://github.com/me/app/pull/9"))
    }
}
