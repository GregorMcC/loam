import Foundation
import Testing

@testable import LoamKit

/// Ticket 115: what Start work… takes from a link. The branch name and the goal come from the label of the link, and
/// the link must be an issue. The sheet shows the same words that these functions give.
@Suite struct IssueLinkTests {
    @Test func aLinearIssueHasItsIssueID() throws {
        let issue = try #require(IssueLink(target: "https://linear.app/example/issue/eng-482/link-kinds-for-figma"))
        #expect(issue.service == .linear)
        #expect(issue.id == "ENG-482")
        #expect(issue.connector == "Linear")
    }

    @Test func aGitHubIssueHasItsNumber() throws {
        let issue = try #require(IssueLink(target: "https://github.com/example/widgets/issues/57"))
        #expect(issue.service == .github)
        #expect(issue.id == "57")
        #expect(issue.connector == "GitHub")
    }

    @Test func theHostMayHaveWWWAndOtherCase() {
        #expect(IssueLink(target: "https://www.github.com/Example/Widgets/issues/57")?.id == "57")
        #expect(IssueLink(target: "  https://LINEAR.app/example/issue/ENG-1  ")?.id == "ENG-1")
    }

    @Test func aPullRequestIsNotAnIssue() {
        #expect(IssueLink(target: "https://github.com/example/widgets/pull/57") == nil)
    }

    @Test func otherLinksAreNotIssues() {
        for target in [
            "https://linear.app/example/project/widgets", "https://linear.app/example/issue/not-a-key",
            "https://linear.app/example/issue/ENG-", "https://linear.app/example/issue/-482",
            "https://github.com/example/widgets", "https://github.com/example/widgets/issues",
            "https://github.com/example/widgets/issues/fifty", "https://github.com/example/widgets/issues/57x",
            "https://example.com/example/issue/ENG-482", "https://notion.so/Loam-0123456789abcdef",
            "/Users/someone/notes/issues/57", "~/issues/57", "", "ENG-482", "not a url",
        ] {
            #expect(IssueLink(target: target) == nil, "\(target)")
        }
    }

    /// The core reads `--link` as a URL only when it has "://", else as the ID of a link of the plot. A URL with no scheme
    /// is no issue here either, so the sheet shows its note and never sends it.
    @Test func aUrlWithNoSchemeIsNotAnIssue() {
        for target in [
            "//linear.app/example/issue/ENG-482/link-kinds-for-figma", "linear.app/example/issue/ENG-482",
            "//github.com/example/widgets/issues/57", "github.com/example/widgets/issues/57",
            "https:linear.app/example/issue/ENG-482", "https:/github.com/example/widgets/issues/57",
        ] {
            #expect(IssueLink(target: target) == nil, "\(target)")
        }
    }

    @Test func aGitHubNameWithAControlCharacterIsNotAnIssue() {
        // The core refuses these too, so a link never reaches `--link` with a name that cannot be a key.
        #expect(IssueLink(target: "https://github.com/exa%0Ample/widgets/issues/57") == nil)
    }

    @Test func aPlotLinkOffersStartWorkOnlyAsAnIssueOfItsKind() {
        func link(_ kind: LinkKind, _ target: String) -> PlotLink {
            PlotLink(id: "l", label: "x", target: target, note: "", position: 0, version: 1, kind: kind, exists: nil)
        }
        #expect(link(.linear, "https://linear.app/example/issue/ENG-482/x").issue?.id == "ENG-482")
        #expect(link(.github, "https://github.com/example/widgets/issues/57").issue?.id == "57")
        #expect(link(.github, "https://github.com/example/widgets/pull/57").issue == nil)
        #expect(link(.url, "https://example.com/issue/ENG-482").issue == nil)
        #expect(link(.notion, "https://notion.so/x").issue == nil)
        #expect(link(.path, "/tmp/issues/57").issue == nil)
    }
}

@Suite struct StartWorkNamesTests {
    private func linear(_ id: String = "ENG-482") -> IssueLink { IssueLink(target: "https://linear.app/example/issue/\(id)")! }
    private func github(_ number: Int = 57) -> IssueLink { IssueLink(target: "https://github.com/example/widgets/issues/\(number)")! }

    // MARK: Branch

    @Test func theBranchOfALinearLabelHasTheKeyAndTheTitleInLowerCaseWithHyphens() {
        #expect(StartWorkNames.branch(label: "ENG-482 Link kinds for Figma", issue: linear()) == "eng-482-link-kinds-for-figma")
    }

    @Test func theBranchOfAGitHubLabelStartsWithTheNumber() {
        #expect(StartWorkNames.branch(label: "#57 Fix the switcher width", issue: github()) == "57-fix-the-switcher-width")
        #expect(StartWorkNames.branch(label: "Fix the switcher width", issue: github()) == "57-fix-the-switcher-width")
    }

    @Test func aLabelThatIsOnlyTheKeyGivesTheKey() {
        #expect(StartWorkNames.branch(label: "ENG-482", issue: linear()) == "eng-482")
        // The label that the core gives to a GitHub link with no label.
        #expect(StartWorkNames.branch(label: "widgets#57", issue: github()) == "57")
        #expect(StartWorkNames.branch(label: "", issue: github()) == "57")
    }

    @Test func punctuationBecomesOneHyphen() {
        #expect(StartWorkNames.branch(label: "ENG-482: Fix \"login\" (iOS) / Android!!", issue: linear())
                == "eng-482-fix-login-ios-android")
        #expect(StartWorkNames.branch(label: "ENG-482 -- spaced   out --", issue: linear()) == "eng-482-spaced-out")
    }

    @Test func accentsFoldAndOtherLettersStay() {
        #expect(StartWorkNames.branch(label: "ENG-7 Café crème", issue: linear("ENG-7")) == "eng-7-cafe-creme")
        #expect(StartWorkNames.branch(label: "ENG-7 日本語 ページ", issue: linear("ENG-7")) == "eng-7-日本語-ページ")
    }

    @Test func invisibleCharactersAreDroppedAndCompatibilityFormsFold() {
        func branch(_ label: String) -> String { StartWorkNames.branch(label: label, issue: linear("ENG-7")) }
        // A joiner, a soft hyphen and a direction mark show nothing, so they must not stay in the name.
        #expect(branch("ENG-7 fix\u{200D}bug") == "eng-7-fixbug")
        #expect(branch("ENG-7 fix\u{200C}bug\u{00AD}s") == "eng-7-fixbugs")
        #expect(branch("ENG-7 \u{202E}fix \u{200B}it") == "eng-7-fix-it")
        // A ligature, a fraction, a superscript and a Roman numeral take their plain letters and digits.
        #expect(branch("ENG-7 o\u{FB03}ce") == "eng-7-office")
        #expect(branch("ENG-7 \u{00BD} x\u{00B2} \u{217B}") == "eng-7-1-2-x2-xii")
    }

    @Test func aLongBranchIsCutAtAWordBreakAt60Characters() {
        let label = "ENG-482 Make the link kinds for Figma and Notion work in the switcher and the panel"
        let branch = StartWorkNames.branch(label: label, issue: linear())
        #expect(branch == "eng-482-make-the-link-kinds-for-figma-and-notion-work-in-the")
        #expect(branch.count <= 60)
        // The cut does not leave half a word, and it leaves no hyphen at the end.
        #expect(!branch.hasSuffix("-"))
    }

    @Test func aBranchOfExactly60CharactersIsKept() {
        // "eng-482-" is 8 characters, so a 52 character word makes 60.
        let word = String(repeating: "a", count: 52)
        #expect(StartWorkNames.branch(label: "ENG-482 \(word)", issue: linear()) == "eng-482-\(word)")
    }

    @Test func aCutThatFallsOnAHyphenKeepsTheWordBefore() {
        // The 61st character is the hyphen, so the word before it is whole.
        let whole = String(repeating: "b", count: 52)
        #expect(StartWorkNames.branch(label: "ENG-482 \(whole) tail", issue: linear()) == "eng-482-\(whole)")
        // The 60th character is the hyphen, and the branch does not end in it.
        let short = String(repeating: "b", count: 51)
        #expect(StartWorkNames.branch(label: "ENG-482 \(short) tail", issue: linear()) == "eng-482-\(short)")
    }

    @Test func oneLongWordIsCutAtTheLimitAfterTheKey() {
        let word = String(repeating: "c", count: 80)
        // The key is a whole word, and the long word has no break, so the cut keeps the key.
        #expect(StartWorkNames.branch(label: "ENG-482 \(word)", issue: linear()) == "eng-482")
    }

    @Test func aKeyThatIsLongerThanTheLimitIsCutHard() {
        let id = "A" + String(repeating: "B", count: 70) + "-1"
        let issue = IssueLink(target: "https://linear.app/example/issue/\(id)")!
        #expect(StartWorkNames.branch(label: id, issue: issue).count == 60)
    }

    // MARK: Goal

    @Test func theGoalIsTheLabelWithoutItsKey() {
        #expect(StartWorkNames.goal(label: "ENG-482 Link kinds for Figma", issue: linear()) == "Link kinds for Figma")
        #expect(StartWorkNames.goal(label: "#57 Fix the switcher width", issue: github()) == "Fix the switcher width")
        #expect(StartWorkNames.goal(label: "example/widgets#57: Fix the switcher width", issue: github()) == "Fix the switcher width")
        #expect(StartWorkNames.goal(label: "[ENG-482] - Link kinds for Figma", issue: linear()) == "Link kinds for Figma")
    }

    @Test func aLabelWithoutAKeyIsTheGoalAsItIs() {
        #expect(StartWorkNames.goal(label: "Link kinds for Figma", issue: linear()) == "Link kinds for Figma")
    }

    @Test func aLabelThatIsOnlyTheKeyGivesNoGoal() {
        #expect(StartWorkNames.goal(label: "ENG-482", issue: linear()) == "")
        #expect(StartWorkNames.goal(label: "widgets#57", issue: github()) == "")
        #expect(StartWorkNames.goal(label: "", issue: github()) == "")
    }

    @Test func theKeyOfAnotherIssueStays() {
        #expect(StartWorkNames.goal(label: "ENG-999 Blocked by this", issue: linear()) == "ENG-999 Blocked by this")
    }

    @Test func theGoalIsOneLine() {
        #expect(StartWorkNames.goal(label: "ENG-482 Link\nkinds   for\tFigma ", issue: linear()) == "Link kinds for Figma")
    }

    @Test func theKeyMatchesWithoutRegardToCase() {
        #expect(StartWorkNames.goal(label: "eng-482 Link kinds", issue: linear()) == "Link kinds")
    }
}

@Suite struct WorktreeGoalTests {
    @Test func countsWordsLikeTheCore() {
        #expect(WorktreeGoal.words(in: "") == 0)
        #expect(WorktreeGoal.words(in: "  Link   kinds\nfor\tFigma ") == 4)
    }

    @Test func twentyWordsHaveNoWarning() {
        #expect(WorktreeGoal.warning(for: Array(repeating: "word", count: 20).joined(separator: " ")) == nil)
    }

    @Test func moreThanTwentyWordsWarnWithTheCountAndTheLimit() {
        let goal = Array(repeating: "word", count: 24).joined(separator: " ")
        #expect(WorktreeGoal.warning(for: goal) == "The goal has 24 words. The soft limit is 20 words.")
        #expect(WorktreeGoal.warning(for: goal + " more") == "The goal has 25 words. The soft limit is 20 words.")
    }

    @Test func theBoardGoalIsOverTheLimit() {
        let goal = "Add Figma as a link kind with its own mark, label rules and a preview in the switcher and the panel for each plot"
        #expect(WorktreeGoal.words(in: goal) == 24)
        #expect(WorktreeGoal.warning(for: goal) == "The goal has 24 words. The soft limit is 20 words.")
    }
}
