import Foundation

/// What you put into a pane, for the composer rule of `PaneSession` (ticket 110). The terminal view sorts each key
/// down with `init(keyCode:characters:mods:isARepeat:composing:)`, a pure rule, so tests cover it.
public enum PaneInput: Equatable, Sendable {
    /// A plain Return or keypad Enter. It sends the composer, or does nothing when the composer is empty. In a
    /// dialog it answers.
    case submit
    /// A typed digit 1 to 9. In a dialog it picks an option. Elsewhere it is a key like any other.
    case pick
    /// Escape. In a dialog it denies. It counts as input everywhere.
    case escape
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
    /// The characters that pick an option of a dialog. Loam reads the character, not the key code, because AZERTY
    /// needs ⇧ for a digit.
    static let pickCharacters: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    /// - Parameters:
    ///   - characters: the characters of the event, with its modifiers applied.
    ///   - composing: an input method shows marked text. Return and Escape then end the composition, and a digit
    ///     picks a candidate.
    public init(keyCode: UInt16, characters: String?, mods: KeyChord.Mods, isARepeat: Bool, composing: Bool) {
        if mods.contains(.command) {
            self = Self.deleteKeys.contains(keyCode) ? .key : .none
        } else if composing {
            self = .key
        } else if Self.returnKeys.contains(keyCode), mods.isEmpty {
            self = isARepeat ? .none : .submit
        } else if keyCode == Self.escapeKey {
            self = .escape
        } else if !mods.contains(.control), let characters, Self.pickCharacters.contains(characters) {
            self = .pick
        } else {
            self = .key
        }
    }
}
