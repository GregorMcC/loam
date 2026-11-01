import Foundation
import Testing

@testable import LoamKit

/// TAS-61: the review row of the desk. The text of a comment is a few plain lines, and the decision chooses the main
/// action.
@Suite struct DeskReviewTests {
    // MARK: Plain text

    /// A comment of a review bot: a header in italics, a bold title, code, a link, a block of details, and a comment of
    /// HTML. It is made up, in the form that such bots write.
    static let bot = """
        _\u{26A0}\u{FE0F} Potential issue_ | _\u{1F7E0} Major_

        **A label match can outrank a title match.**

        `labelWeight` is `0.8`, so a label that scores 1.0 passes a title that scores 0.7. See [the scorer](https://example.com/score).

        <details>
        <summary>Suggested change</summary>

        ```suggestion
        const labelWeight = 0.5
        ```

        <details><summary>Inner</summary>Inner text</details>

        </details>

        <!-- fingerprinting:phantom:made-up -->
        """

    @Test func theBodyOfABotCommentIsItsFirstThreePlainLines() {
        #expect(DeskReview.plainText(Self.bot) == """
            \u{26A0}\u{FE0F} Potential issue | \u{1F7E0} Major
            A label match can outrank a title match.
            labelWeight is 0.8, so a label that scores 1.0 passes a title that scores 0.7. See the scorer.
            """)
    }

    @Test func aDetailsBlockThatNeverClosesAndACommentThatNeverEndsAreCut() {
        #expect(DeskReview.plainText("Fix this.\n<details>\n<summary>More</summary>\nLong text") == "Fix this.")
        #expect(DeskReview.plainText("Fix this.<!-- never closed") == "Fix this.")
    }

    @Test func nestedDetailsBlocksGoInOnePass() {
        let depth = 5000
        let nested = String(repeating: "<details>", count: depth) + "inner" + String(repeating: "</details>", count: depth)
        #expect(DeskReview.plainText("Before.\n" + nested + "\nAfter.") == "Before.\nAfter.")
        #expect(DeskReview.plainText("a <details>x</details> b <details>y</details> c") == "a  b  c".replacingOccurrences(of: "  ", with: " "))
    }

    @Test func htmlTagsGoAndTheirTextStays() {
        #expect(DeskReview.plainText("Use <code>Match</code> here.<br>Then <b>stop</b>.&nbsp;Done &amp; dusted.")
            == "Use Match here.\nThen stop. Done & dusted.")
    }

    @Test func markdownMarkupGoes() {
        let markdown = """
            ## Heading
            > A quote with *emphasis* and __strong__ and ~~gone~~
            - [ ] a task
            1. a step with snake_case_name and 2 * 3 * 4
            ---
            ![a picture](https://example.com/p.png)
            """
        #expect(DeskReview.plainText(markdown, lines: 10) == """
            Heading
            A quote with emphasis and strong and gone
            [ ] a task
            a step with snake_case_name and 2 * 3 * 4
            a picture
            """)
    }

    @Test func aLongLineEndsInAnEllipsisAndNoTextGivesNoLines() {
        let long = String(repeating: "a", count: DeskReview.lineLength + 50)
        #expect(DeskReview.plainText(long) == String(repeating: "a", count: DeskReview.lineLength) + "\u{2026}")
        #expect(DeskReview.plainText("") == "")
        #expect(DeskReview.plainText("<details>All of it</details>\n\n  \n") == "")
        #expect(DeskReview.plainText("one\r\ntwo\r\nthree\r\nfour") == "one\ntwo\nthree")
    }

    // MARK: The row

    static func pr(decision: String, threads: [PRReviewThread] = [], requests: [PRReview] = []) throws -> PullRequest {
        let json = """
            {"number": 7, "title": "T", "url": "https://github.com/example/widgets/pull/7", "state": "OPEN", "draft": false,
             "mergeable": "MERGEABLE", "merge_state": "CLEAN", "review_decision": "\(decision)", "in_merge_queue": false,
             "queue_position": 0, "base": "main", "head": "x", "head_oid": "abc", "commits": 1, "behind_base": 0, "approvals": 0,
             "comments": \(threads.count), "checks": {"state": "SUCCESS", "total": 1, "passed": 1, "failed": 0, "running": 0,
             "waiting": 0, "required": 0, "required_passed": 0}, "failed_checks": [], "passed_checks": []}
            """
        var pr = try JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
        pr.reviewThreads = threads
        pr.changeRequests = requests
        return pr
    }

    static func thread(_ id: String, path: String, line: Int, body: String, author: String = "alice") -> PRReviewThread {
        PRReviewThread(id: id, path: path, line: line, url: "https://github.com/example/widgets/pull/7#discussion_\(id)",
                       comments: [PRReviewComment(author: author, writer: true, body: body, url: "")])
    }

    static func review(_ pr: PullRequest, threads: Int? = nil, reviews: Int = 0) throws -> DeskReview {
        return DeskReview(RunReview(run: TodayContentTests.run("r1", plot: "p1", .ready), pr: pr,
                                    threads: threads ?? pr.reviewThreads?.count ?? 0, reviews: reviews))
    }

    @Test func changesRequestedWithTwoThreadsListsTheTwoCommentsAndSendsBackFirst() throws {
        let pr = try Self.pr(decision: "CHANGES_REQUESTED", threads: [
            Self.thread("T1", path: "search/match.go", line: 8, body: Self.bot, author: "reviewbot"),
            Self.thread("T2", path: "search/match_test.go", line: 0, body: "Add a case for a link with no label."),
        ])
        let review = try Self.review(pr)
        #expect(review.decision == .changesRequested && review.sendBackIsPrimary && review.canSendBack)
        #expect(review.line.title == "Review \u{00B7} Changes requested" && review.line.caption == "2 open threads")
        #expect(review.comments.map(\.reviewer) == ["reviewbot", "alice"])
        // A thread on a line that the head no longer has shows its file only.
        #expect(review.comments.map(\.place) == ["search/match.go:8", "search/match_test.go"])
        #expect(review.comments[1].excerpt == "Add a case for a link with no label.")
        #expect(review.comments[0].url == "https://github.com/example/widgets/pull/7#discussion_T1")
        #expect(review.comments[0].excerpt.split(separator: "\n").count == DeskReview.excerptLines)
    }

    @Test func aReviewBodyThatRequestsChangesIsACommentToo() throws {
        let pr = try Self.pr(decision: "CHANGES_REQUESTED", requests: [
            PRReview(id: "R1", author: "alice", body: "Two things before this merges.", url: "https://example.com/r1"),
            PRReview(id: "R2", author: "bob", body: "  \n", url: ""),
        ])
        let review = try Self.review(pr, reviews: 1)
        #expect(review.comments.map(\.place) == ["Review"] && review.comments[0].excerpt == "Two things before this merges.")
        #expect(review.line.caption == "No open threads" && review.sendBackIsPrimary)
    }

    @Test func anApprovedPRKeepsMergeFirstAndOffersSendBackWhileAThreadIsOpen() throws {
        let pr = try Self.pr(decision: "APPROVED", threads: [Self.thread("T1", path: "a.go", line: 1, body: "Nit.")])
        let review = try Self.review(pr)
        #expect(review.decision == .approved && !review.sendBackIsPrimary && review.canSendBack)
        #expect(review.line.mark == .tick && review.line.caption == "1 open thread")
    }

    @Test func changesRequestedWithNothingToSendKeepsMergeFirst() throws {
        // The session resolved each thread, and GitHub keeps the decision until the reviewer reviews again.
        let review = try Self.review(try Self.pr(decision: "CHANGES_REQUESTED"), threads: 0, reviews: 0)
        #expect(review.decision == .changesRequested && !review.canSendBack && !review.sendBackIsPrimary)
        // Threads that only readers wrote have nothing to send either.
        let readers = try Self.pr(decision: "CHANGES_REQUESTED", threads: [Self.thread("T1", path: "a.go", line: 1, body: "x")])
        #expect(!(try Self.review(readers, threads: 0)).sendBackIsPrimary)
    }

    @Test func theOtherDecisionsHaveTheirOwnWords() throws {
        let required = try Self.review(try Self.pr(decision: "REVIEW_REQUIRED"))
        #expect(required.decision == .reviewRequired && required.line.title == "Review \u{00B7} Review required")
        let none = try Self.review(try Self.pr(decision: ""))
        #expect(none.decision == .none && none.line.title == "Review \u{00B7} None" && none.line.caption == "No open threads")
        #expect(!none.sendBackIsPrimary && !none.canSendBack)
        #expect(DeskReview.unreadLine("gh is signed out").title == "Review \u{00B7} not read")
    }
}
