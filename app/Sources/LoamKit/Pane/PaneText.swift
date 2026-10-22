import Foundation

/// Text that the app types into a pane for you to read and send (ADR 0007: Loam never sends a prompt).
public enum PaneText {
    /// `text` without the line breaks at its end. A paste that ends in a line break presses Return in
    /// a program that takes no bracketed paste, and that would run the command or send the prompt.
    /// A line break inside the text stays: a program that takes a paste keeps it as text.
    public static func withoutReturn(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isNewline { text.removeLast() }
        return text
    }
}
