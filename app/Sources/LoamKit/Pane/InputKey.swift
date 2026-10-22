import Foundation

/// What a key down in a terminal does to the input of Claude Code (ticket 110). A pure rule, so tests cover it.
/// The terminal view reads the key code, the modifiers and the repeat flag of the event.
public enum InputKey: Equatable, Sendable {
    /// A plain Return. It sends the input, or does nothing when the input is empty.
    case submit
    /// The key can put text into the input or change it.
    case input
    /// The key leaves the input as it is, such as a ⌘ key that scrolls or moves the focus, or a held Return.
    case none

    /// Return, and Enter on the keypad.
    static let returnKeys: Set<UInt16> = [0x24, 0x4C]
    /// Delete and forward delete. With ⌘ they clear the line.
    static let deleteKeys: Set<UInt16> = [0x33, 0x75]

    /// - Parameter composing: an input method shows marked text. Return then ends the composition.
    public init(keyCode: UInt16, mods: KeyChord.Mods, isARepeat: Bool, composing: Bool) {
        if mods.contains(.command) {
            self = Self.deleteKeys.contains(keyCode) ? .input : .none
        } else if Self.returnKeys.contains(keyCode), mods.isEmpty, !composing {
            self = isARepeat ? .none : .submit
        } else {
            self = .input
        }
    }
}
