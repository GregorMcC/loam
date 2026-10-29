import Foundation

/// The review of the PR of a run that is ready to land (TAS-61): its decision, its open threads, and the text of each
/// comment as a few plain lines. The desk draws it as a row of the evidence that opens to the comments. The core
/// reads the review. The views only draw it.
public struct DeskReview: Equatable, Sendable {
    /// The review decision of GitHub for the PR.
    public enum Decision: Equatable, Sendable {
        case approved, changesRequested, reviewRequired
        /// The base branch needs no review, so the decision is empty.
        case none
    }

    /// One comment to read: the first comment of a thread that is not resolved, or the body of a review that
    /// requests changes.
    public struct Comment: Equatable, Sendable, Identifiable {
        public var id: String
        public var reviewer: String
        /// `file:line`, `file` when the head no longer has the line, or "Review" for the body of a review.
        public var place: String
        /// The first lines of the text, with no markup.
        public var excerpt: String
        /// The page of the thread or review on GitHub. Empty when GitHub gave none.
        public var url: String
    }

    /// The most lines of a comment that the desk shows.
    public static let excerptLines = 3
    /// The most characters of a line of a comment that the desk shows. A longer line ends in an ellipsis.
    public static let lineLength = 240

    public var number: Int
    public var decision: Decision
    /// The threads that are not resolved.
    public var threads: Int
    public var comments: [Comment]
    /// What the core would send back: the threads with a comment by a writer, and the reviews that it has not sent.
    public var sendableThreads: Int
    public var sendableReviews: Int

    /// True when the core has a review to send back.
    public var canSendBack: Bool { sendableThreads + sendableReviews > 0 }

    /// "Send review back" is the main action: the review requests changes and there is something to send. Else
    /// Merge is the main action. A review that stays on GitHub after the core sent it and the session resolved
    /// each thread has nothing to send, so it does not stop the merge.
    public var sendBackIsPrimary: Bool { decision == .changesRequested && canSendBack }

    public init(_ review: RunReview) {
        let pr = review.pr
        number = pr.number
        switch pr.reviewDecision {
        case "APPROVED": decision = .approved
        case "CHANGES_REQUESTED": decision = .changesRequested
        case "REVIEW_REQUIRED": decision = .reviewRequired
        default: decision = .none
        }
        let threads = pr.reviewThreads ?? []
        self.threads = pr.comments
        sendableThreads = review.threads
        sendableReviews = review.reviews
        var comments = threads.compactMap { thread -> Comment? in
            guard let first = thread.comments.first else { return nil }
            let place = thread.line > 0 ? "\(thread.path):\(thread.line)" : thread.path
            return Comment(id: thread.id, reviewer: first.author, place: place,
                           excerpt: Self.plainText(first.body), url: thread.url)
        }
        comments += (pr.changeRequests ?? []).filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Comment(id: $0.id, reviewer: $0.author, place: "Review", excerpt: Self.plainText($0.body), url: $0.url) }
        self.comments = comments
    }

    /// The row of the evidence: the decision, and the open threads.
    public var line: DeskContent.EvidenceLine {
        let title: String
        switch decision {
        case .approved: title = "Approved"
        case .changesRequested: title = "Changes requested"
        case .reviewRequired: title = "Review required"
        case .none: title = "None"
        }
        let caption = threads == 0 ? "No open threads" : threads == 1 ? "1 open thread" : "\(threads) open threads"
        let mark: DeskContent.EvidenceLine.Mark = switch decision {
        case .approved: .tick
        case .changesRequested: .count(max(threads, 1))
        case .reviewRequired, .none: .none
        }
        return DeskContent.EvidenceLine(id: "review", mark: mark, title: "Review \u{00B7} \(title)", caption: caption)
    }

    /// The row when the core could not read the review: it says why.
    public static func unreadLine(_ reason: String) -> DeskContent.EvidenceLine {
        DeskContent.EvidenceLine(id: "review", mark: .none, title: "Review \u{00B7} not read", caption: reason)
    }

    // MARK: Plain text

    /// The text of a comment as plain lines: the first `lines` lines with text, with no HTML, no `<details>` block,
    /// and no Markdown markup. The comments of a review bot are long and full of HTML, and the desk shows no
    /// rendered Markdown. A line ends in an ellipsis after `lineLength` characters.
    public static func plainText(_ markdown: String, lines: Int = excerptLines) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        text = Self.regex(#"<!--[\s\S]*?(-->|$)"#).replace(in: text, with: "")
        // A <details> block holds the long part of a bot comment. Inner blocks go first, then the outer one.
        let inner = Self.regex(#"<details\b(?:(?!<details\b)[\s\S])*?(</details\s*>|$)"#)
        while true {
            let next = inner.replace(in: text, with: "")
            if next == text { break }
            text = next
        }
        text = Self.regex(#"<(br|/p|/li|/div|/h[1-6]|/tr)\b[^>]*>"#).replace(in: text, with: "\n")
        text = Self.regex(#"</?[A-Za-z][^>]*>"#).replace(in: text, with: "")
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Self.plainLine(String(raw))
            if !line.isEmpty { out.append(line) }
            if out.count == lines { break }
        }
        return out.joined(separator: "\n")
    }

    /// One line of Markdown as plain text. A line of a code fence, or a rule, has no text.
    private static func plainLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return "" }
        if Self.regex(#"^([-*_=]\s*){3,}$"#).matches(line) { return "" }
        line = Self.regex(#"^(#{1,6}\s+|>\s?|[-*+]\s+|\d+[.)]\s+)+"#).replace(in: line, with: "")
        line = Self.regex(#"!\[([^\]]*)\]\([^)]*\)"#).replace(in: line, with: "$1")
        line = Self.regex(#"\[([^\]]*)\]\([^)]*\)"#).replace(in: line, with: "$1")
        line = Self.regex(#"(\*\*|__|~~)(.+?)\1"#).replace(in: line, with: "$2")
        line = Self.regex(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#).replace(in: line, with: "$1")
        line = Self.regex(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#).replace(in: line, with: "$1")
        line = Self.regex("`+([^`]*)`+").replace(in: line, with: "$1")
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            line = line.replacingOccurrences(of: entity, with: character)
        }
        line = Self.regex(#"\s+"#).replace(in: line, with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > lineLength ? String(line.prefix(lineLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : line
    }

    private static func regex(_ pattern: String) -> Pattern { Pattern(pattern) }

    /// A pattern that is known to be right: the patterns of this file are constants.
    private struct Pattern {
        let expression: NSRegularExpression

        init(_ pattern: String) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                preconditionFailure("The pattern \(pattern) is not valid")
            }
            self.expression = expression
        }

        func replace(in text: String, with template: String) -> String {
            expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }

        func matches(_ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
