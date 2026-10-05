import Foundation

/// One key with its modifiers, such as ⌘⇧P. Loam compares keys from three places with it:
/// its own fixed keys, the `keybind` lines of a Ghostty config, and the key events of a pane.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public struct Mods: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Mods(rawValue: 1 << 0)
        public static let option = Mods(rawValue: 1 << 1)
        public static let shift = Mods(rawValue: 1 << 2)
        public static let command = Mods(rawValue: 1 << 3)
    }

    public var mods: Mods
    /// A lowercase character ("p", "1", ","), or the snake-case name of a key with no
    /// character ("arrow_up", "enter").
    public var key: String

    public init(_ mods: Mods, _ key: String) {
        self.mods = mods
        self.key = key.lowercased()
    }

    /// The macOS form, such as "⌃⌥⇧⌘P".
    public var description: String {
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key)
    }

    // MARK: Ghostty triggers

    /// Parses one Ghostty trigger, such as "cmd+shift+p", "super+digit_1", or "ctrl+one".
    /// It follows `Trigger.parse` in Ghostty's `src/input/Binding.zig`: modifiers and their
    /// aliases, one key, and an empty part for a literal "+". It returns nil for a trigger
    /// that Loam cannot compare, such as `catch_all` or a repeated modifier.
    public static func ghosttyTrigger(_ text: String) -> KeyChord? {
        guard !text.isEmpty else { return nil }
        var mods: Mods = []
        var key: String?
        var rest = Substring(text)
        while !rest.isEmpty {
            let part: Substring
            if let plus = rest.firstIndex(of: "+") {
                part = rest[..<plus]
                rest = rest[rest.index(after: plus)...]
            } else {
                part = rest
                rest = ""
            }
            if let mod = modNames[String(part)] {
                if mods.contains(mod) { return nil }
                mods.insert(mod)
                continue
            }
            guard key == nil else { return nil }
            key = part.isEmpty ? "+" : keyName(String(part))
            guard key != nil else { return nil }
        }
        guard let key else { return nil }
        return KeyChord(mods, key)
    }

    private static let modNames: [String: Mods] = [
        "shift": .shift,
        "ctrl": .control, "control": .control,
        "alt": .option, "opt": .option, "option": .option,
        "super": .command, "cmd": .command, "command": .command,
    ]

    /// Ghostty's physical, W3C, and old (1.1) key names, mapped to the character that the
    /// key types on a US layout. A single character stands for itself.
    private static let namedKeys: [String: String] = {
        var names: [String: String] = [
            "backquote": "`", "grave_accent": "`", "Backquote": "`",
            "backslash": "\\", "Backslash": "\\",
            "bracket_left": "[", "left_bracket": "[", "BracketLeft": "[",
            "bracket_right": "]", "right_bracket": "]", "BracketRight": "]",
            "comma": ",", "Comma": ",",
            "equal": "=", "Equal": "=",
            "minus": "-", "Minus": "-",
            "period": ".", "Period": ".",
            "quote": "'", "apostrophe": "'", "Quote": "'",
            "semicolon": ";", "Semicolon": ";",
            "slash": "/", "Slash": "/",
            "plus": "+",
        ]
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for (n, word) in digits.enumerated() {
            names["digit_\(n)"] = "\(n)"
            names["Digit\(n)"] = "\(n)"
            names[word] = "\(n)"
        }
        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            let letter = String(UnicodeScalar(scalar)!)
            names["key_\(letter)"] = letter
            names["Key\(letter.uppercased())"] = letter
        }
        return names
    }()

    private static func keyName(_ part: String) -> String? {
        if let name = namedKeys[part] { return name }
        if part == "catch_all" { return nil }
        if part.count == 1 { return part.lowercased() }
        // Any other name (arrow_up, enter, f1) stands for itself. A W3C name (ArrowUp) becomes snake case.
        var snake = ""
        for (i, character) in part.enumerated() {
            if character.isUppercase, i > 0 { snake += "_" }
            snake += character.lowercased()
        }
        return snake
    }
}
