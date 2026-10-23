import AppKit

extension WindowRef {
    /// True while the text field that has the keys holds text that an input method has not finished, such as a Japanese
    /// or a Chinese composition. Escape then cancels the composition. A view that closes on Escape must leave the key to
    /// the input method: it returns `.ignored`, and so must each handler above it that closes something.
    var isComposing: Bool {
        ((window ?? NSApp.keyWindow)?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}
