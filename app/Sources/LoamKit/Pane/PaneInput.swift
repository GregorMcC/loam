import Foundation

/// What you put into a pane, for the composer rule of `PaneSession` (ticket 110). The terminal view sorts each key
/// down with `init(keyCode:characters:unshifted:mods:isARepeat:composing:)`, a pure rule, so tests cover it.
public enum PaneInput: Equatable, Sendable {
    /// A plain Return or keypad Enter. It sends the composer, or does nothing when the composer is empty. In a
    /// dialog it answers.
    case submit
    /// A typed digit 1 to 9. In a dialog it picks an option. Elsewhere it is a key like any other.
    case pick
    /// Escape. In a dialog it denies. It counts as input everywhere.
    case escape
    /// ⌃S, which stashes the draft of Claude Code (`chat:stash`). Claude Code puts the draft back when you submit.
    case stash
    /// Any other key that can put text into the composer or change it.
    case key
    /// A paste, a drop, or text from dictation or a picker. It does not come from a key down.
    case text
    /// A key that leaves the composer as it is, such as a ⌘ key that scrolls or moves the focus, or a held Return.
    case none

    /// Return, and Enter on the keypad.
    static let returnKeys: Set<UInt16> = [0x24, 0x4C]
    /// Delete and forward delete. With ⌘ they clear the line.
    static let deleteKeys: Set<UInt16> = [0x33, 0x75]
    static let escapeKey: UInt16 = 0x35
    /// The key code of the physical S key.
    static let sKey: UInt16 = 0x01
    /// The characters that pick an option of a dialog. Loam reads the character, not the key code, because AZERTY
    /// needs ⇧ for a digit.
    static let pickCharacters: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// - Parameters:
    ///   - characters: the characters of the event, with its modifiers applied.
    ///   - unshifted: the characters of the event with no modifiers, as the view gives libghostty for
    ///     `unshifted_codepoint`.
    ///   - composing: an input method shows marked text. Return and Escape then end the composition, and a digit
    ///     picks a candidate.
    public init(keyCode: UInt16, characters: String?, unshifted: String?, mods: KeyChord.Mods, isARepeat: Bool,
                composing: Bool) {
        if mods.contains(.command) {
            self = Self.deleteKeys.contains(keyCode) ? .key : .none
        } else if composing {
            self = .key
        } else if Self.returnKeys.contains(keyCode), mods.isEmpty {
            self = isARepeat ? .none : .submit
        } else if keyCode == Self.escapeKey {
            self = .escape
        } else if mods == .control, Self.sendsControlS(keyCode: keyCode, characters: characters, unshifted: unshifted) {
            self = .stash
        } else if !mods.contains(.control), let characters, Self.pickCharacters.contains(characters) {
            self = .pick
        } else {
            self = .key
        }
    }

    /// True when libghostty sends a key that Claude Code reads as ctrl+s, with ⌃ only. libghostty has two encoders.
    /// Claude Code turns on the kitty keyboard protocol in libghostty, and an older Claude Code gets the legacy
    /// encoder. Loam cannot see which one runs, so it counts the key when either one sends ctrl+s. On Yiddish
    /// QWERTY, only the legacy encoder sends it. On Dvorak-QWERTY ⌘, only the kitty encoder sends it.
    static func sendsControlS(keyCode: UInt16, characters: String?, unshifted: String?) -> Bool {
        let scalars = Array((characters ?? "").unicodeScalars)
        // The view gives libghostty the unshifted text when the event gives a control character.
        let text = (scalars.count == 1 && scalars[0].value < 0x20 ? unshifted : characters) ?? ""
        return legacySendsControlS(keyCode: keyCode, text: text)
            || kittySendsControlS(keyCode: keyCode, text: text, unshifted: unshifted)
    }

    /// The legacy encoder reads the text when it is one ASCII character. When it is not, as on Hebrew or Russian,
    /// the encoder reads the physical key.
    static func legacySendsControlS(keyCode: UInt16, text: String) -> Bool {
        if text.unicodeScalars.count == 1, text.unicodeScalars.allSatisfy(\.isASCII) { return text.lowercased() == "s" }
        return keyCode == sKey
    }

    /// The kitty encoder sends the unshifted character. When that character is not ASCII, Claude Code reads the
    /// physical key that the encoder sends with it. The encoder sends that key only when the text is empty, or is
    /// one character that is not the character of the key.
    static func kittySendsControlS(keyCode: UInt16, text: String, unshifted: String?) -> Bool {
        guard let key = unshifted?.unicodeScalars.first else { return false }
        if key.isASCII { return String(key).lowercased() == "s" }
        return keyCode == sKey && (text.isEmpty || (text.unicodeScalars.count == 1 && text != "s"))
    }
}
