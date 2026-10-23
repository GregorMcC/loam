import AppKit
import Testing

@testable import LoamKit

/// Ticket 112: Return in the Land sheet merges, except when the Where it stands box has the keys. The box is an editable
/// text view (the field editor). A text view that only shows text, such as the callout with the message of GitHub that you
/// select to copy, must not stop the Return.
@MainActor
@Suite struct LandSheetKeysTests {
    @Test func anEditableTextViewIsTheBox() {
        let box = NSTextView()
        box.isEditable = true
        #expect(LandSheetKeys.editor(of: box) === box)
        let fieldEditor = NSTextView()
        fieldEditor.isFieldEditor = true
        #expect(LandSheetKeys.editor(of: fieldEditor) === fieldEditor, "a field editor takes typed text")
    }

    @Test func aTextViewThatOnlyShowsTextIsNotTheBox() {
        let callout = NSTextView()
        callout.isEditable = false
        callout.isSelectable = true
        #expect(LandSheetKeys.editor(of: callout) == nil, "select the message of GitHub, and Return still merges")
    }

    @Test func nothingElseIsTheBox() {
        #expect(LandSheetKeys.editor(of: nil) == nil)
        #expect(LandSheetKeys.editor(of: NSView()) == nil, "the sheet or the terminal has the keys")
    }
}
