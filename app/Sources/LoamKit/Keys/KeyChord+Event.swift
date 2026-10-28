import AppKit

// The app target uses these with or without GhosttyKit, so they live in LoamKit.
extension KeyChord {
    /// The chord of a key event: its modifiers and the character the key types with no modifier.
    public init?(event: NSEvent) {
        guard let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              let first = characters.first else { return nil }
        self.init(Mods(event.modifierFlags), String(first))
    }
}

extension KeyChord.Mods {
    /// The four modifiers of an event. Caps Lock, Fn and the keypad flag do not count.
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}
