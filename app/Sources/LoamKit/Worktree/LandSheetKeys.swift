import AppKit

/// What the Land sheet asks of its window before a Return merges (ticket 112).
public enum LandSheetKeys {
    /// The text view that takes typed text, when it has the keys: the field editor of the Where it stands box. A text view
    /// that only shows text and lets you select it, such as the callout with the message of GitHub, is not one, so Return
    /// still merges while you hold a selection of it.
    @MainActor
    public static func editor(of responder: NSResponder?) -> NSTextView? {
        guard let text = responder as? NSTextView, text.isEditable else { return nil }
        return text
    }
}
