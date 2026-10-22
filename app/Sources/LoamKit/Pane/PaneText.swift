import Foundation

/// Text that the app types into a pane for you to read and send (ADR 0007: Loam never sends a prompt).
public enum PaneText {
    /// `text` as the app may type it: without the line breaks at its end. A paste that ends in a line
    /// break presses Return in a program that takes no bracketed paste, and that would run the command
    /// or send the prompt. A line break inside the text does the same, so text with one is refused.
    public static func withoutReturn(_ text: String) throws -> String {
        var text = text
        while let last = text.last, last.isNewline { text.removeLast() }
        guard !text.contains(where: \.isNewline) else { throw PaneTextError.lineBreakInside }
        return text
    }
}

/// Why the app does not type some text into a pane.
public enum PaneTextError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The text has a line break inside it, after the line breaks at its end are dropped.
    case lineBreakInside

    /// The words for a person. Simplified Technical English.
    public var description: String {
        switch self {
        case .lineBreakInside:
            "Loam does not type text that has a line break inside it. A program with no bracketed paste reads it as Return."
        }
    }
}
