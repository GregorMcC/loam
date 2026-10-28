import Testing

@testable import LoamKit

/// The desk names the worktree that a run gets when you approve it, as the core names it (`freeName` in
/// core/internal/run/run.go). The cases are the names that the core tests expect.
@Suite struct RunWorktreeNameTests {
    @Test func theNameIsTheKeyAndTheTitleAsASlug() {
        #expect(RunWorktreeName.name(title: "Drag a link to reorder", key: "", taken: []) == "drag-a-link-to-reorder")
        #expect(RunWorktreeName.name(title: "Drag a link to reorder", key: "ENG-523", taken: [])
            == "eng-523-drag-a-link-to-reorder")
        #expect(RunWorktreeName.name(title: "Quit during a merge", key: "map 135", taken: []) == "map-135-quit-during-a-merge")
        #expect(RunWorktreeName.name(title: "Fix the thing", key: "", taken: []) == "fix-the-thing")
    }

    @Test func aTakenNameGetsANumber() {
        #expect(RunWorktreeName.name(title: "Fix the thing", key: "", taken: ["fix-the-thing"]) == "fix-the-thing-2")
        #expect(RunWorktreeName.name(title: "Fix the thing", key: "", taken: ["fix-the-thing", "fix-the-thing-2"])
            == "fix-the-thing-3")
    }

    @Test func aTitleWithNoLettersIsARun() {
        #expect(RunWorktreeName.name(title: "!!", key: "", taken: []) == "run")
        #expect(RunWorktreeName.name(title: "", key: "", taken: ["run"]) == "run-2")
    }

    /// Only ASCII letters and digits stay. Other characters split the words.
    @Test func theSlugKeepsASCIILettersAndDigits() {
        #expect(RunWorktreeName.slug("Café: the #57 fix_up") == "caf-the-57-fix-up")
        #expect(RunWorktreeName.slug("  Trim  me  ") == "trim-me")
    }

    /// A long slug ends at a whole word. One long word is cut at the limit.
    @Test func aLongSlugEndsAtAWholeWord() {
        let slug = RunWorktreeName.slug("Remember the window size and the place of each plot when it opens again")
        #expect(slug == "remember-the-window-size-and-the-place-of-each")
        #expect(slug.count <= RunWorktreeName.slugMax)
        #expect(RunWorktreeName.slug(String(repeating: "a", count: 60)) == String(repeating: "a", count: 48))
    }

    /// The key is the key of the issue. A recurring run has an ID for its key, so the name has no key.
    @Test func aRecurringRunHasNoKey() {
        var run = TodayContentTests.run("r1", plot: "p1", .shaping)
        run.source = RunSource(kind: "linear", key: "ENG-512", url: "")
        #expect(RunWorktreeName.key(of: run) == "ENG-512")
        run.source = RunSource(kind: "recurring", key: "recuaaaaab", url: "")
        #expect(RunWorktreeName.key(of: run) == "")
        run.source = nil
        #expect(RunWorktreeName.key(of: run) == "")
    }
}
