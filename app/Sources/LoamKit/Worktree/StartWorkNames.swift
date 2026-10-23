import Foundation

/// What the New worktree sheet fills in from a link (ticket 115): the branch name and the goal. Both come from the
/// label of the link, which is what the plot shows, and the sheet sets them only while you have not typed in the field.
public enum StartWorkNames {
    /// The longest branch name that the sheet makes.
    public static let branchLimit = 60

    /// The issue key in lower case, then the label in lower case with hyphens: "eng-482-link-kinds-for-figma" for
    /// Linear, and "57-fix-the-switcher-width" for GitHub issue #57. A name over 60 characters is cut at a hyphen.
    public static func branch(label: String, issue: IssueLink) -> String {
        let key = issue.service == .linear ? issue.id.lowercased() : issue.id
        return cut(slug("\(key) \(title(of: label, issue: issue))"))
    }

    /// The label without its key, as one line: "Link kinds for Figma". Empty when the label is only the key, such as the
    /// "widgets#57" that the core gives to a GitHub link with no label.
    public static func goal(label: String, issue: IssueLink) -> String { title(of: label, issue: issue) }

    // MARK: Words

    /// The label without the key at its start, and without the marks between them ("ENG-482: ", "[ENG-482] - ", "#57 ",
    /// "widgets#57: "). A key of another issue stays.
    private static func title(of label: String, issue: IssueLink) -> String {
        let text = oneLine(label)
        let key: String
        switch issue.service {
        case .linear: key = NSRegularExpression.escapedPattern(for: issue.id)
        // A GitHub key is "#57", "repo#57" or "owner/repo#57".
        case .github: key = "(?:[A-Za-z0-9._-]+/)?(?:[A-Za-z0-9._-]+)?#\(issue.id)"
        }
        let pattern = "^[\\[(]?\(key)(?![A-Za-z0-9])[\\])]?[\\s:.,;\\-\u{2013}\u{2014}]*"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return text }
        return String(text[range.upperBound...])
    }

    /// The text on one line: each run of white space is one space.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The compatibility form first (NFKC): a ligature, a fraction, a superscript and a Roman numeral take their plain
    /// letters and digits. Then each invisible format character goes (joiners, the soft hyphen, direction marks), so the
    /// name is what it looks like. Lower case; every run of characters that are not letters or digits is one hyphen; none
    /// at the ends. A letter with a mark loses the mark when it is a Latin letter ("é" is "e"). Letters of other scripts
    /// stay as they are, since the mark of "ペ" is part of the letter.
    private static func slug(_ text: String) -> String {
        var out = ""
        let visible = String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            $0.properties.generalCategory != .format
        })
        for character in String(visible).lowercased() {
            let folded = isLatin(character) ? String(character).folding(options: .diacriticInsensitive, locale: nil) : String(character)
            for piece in folded {
                if piece.isLetter || piece.isNumber {
                    out.append(piece)
                } else if out.last != "-" {
                    out.append("-")
                }
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isLatin(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return value < 0x250 || (0x1E00...0x1EFF).contains(value)
    }

    /// At most `branchLimit` characters, cut at a hyphen so no word is left in halves. One word that is longer than the
    /// limit is cut at the limit.
    private static func cut(_ name: String) -> String {
        guard name.count > branchLimit else { return name }
        let head = String(name.prefix(branchLimit))
        let next = name[name.index(name.startIndex, offsetBy: branchLimit)]
        let kept = next == "-" ? head : head.lastIndex(of: "-").map { String(head[..<$0]) } ?? head
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// The goal of a worktree (ticket 114, 115). The limit is soft: a longer goal saves, and the sheet and the popover say so.
public enum WorktreeGoal {
    /// `GoalWordLimit` in the core.
    public static let wordLimit = 20

    /// The words of the goal, split at white space as the core splits them.
    public static func words(in goal: String) -> Int {
        goal.split(whereSeparator: \.isWhitespace).count
    }

    /// "The goal has 24 words. The soft limit is 20 words." Nil for a goal within the limit.
    public static func warning(for goal: String) -> String? {
        let count = words(in: goal)
        return count > wordLimit ? "The goal has \(count) words. The soft limit is \(wordLimit) words." : nil
    }
}
