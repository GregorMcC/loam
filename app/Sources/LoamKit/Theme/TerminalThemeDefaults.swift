import Foundation

/// Loam's default Ghostty theme (ticket 55). The defaults file holds one `theme` line and
/// nothing else. It loads before your config files, so your own `theme` line wins. A
/// `background` line in the defaults file would beat your theme, so it never holds one.
public enum TerminalThemeDefaults {
    public static let nightName = "loam-night"
    public static let dayName = "loam-day"

    /// The text of the defaults file. Absolute paths work on every Ghostty version.
    public static func fileText(themesFolder: String) -> String {
        "theme = dark:\(themesFolder)/\(nightName),light:\(themesFolder)/\(dayName)\n"
    }

    /// The folder with `loam-night` and `loam-day`: `Loam.app/Contents/Resources/ghostty-themes`,
    /// else `app/Resources/ghostty-themes` in the source tree (a build run from the package).
    public static func themesFolder(bundle: Bundle = .main) -> String? {
        let manager = FileManager.default
        func holdsThemes(_ path: String) -> Bool {
            manager.fileExists(atPath: path + "/" + nightName) && manager.fileExists(atPath: path + "/" + dayName)
        }
        if let bundled = bundle.resourceURL?.appendingPathComponent("ghostty-themes").path, holdsThemes(bundled) {
            return bundled
        }
        // app/Sources/LoamKit/Theme/TerminalThemeDefaults.swift -> app/Resources/ghostty-themes
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = app.appendingPathComponent("Resources/ghostty-themes").path
        return holdsThemes(source) ? source : nil
    }

    /// Writes the defaults file and returns its path. The file is a cache: Loam rewrites it
    /// when the text differs. Nil when the themes are not found or the write fails.
    public static func writeDefaultsFile(
        themesFolder: String? = themesFolder(), cacheFolder: URL? = nil
    ) -> String? {
        guard let themesFolder else { return nil }
        let manager = FileManager.default
        guard let folder = cacheFolder ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.loam.Loam") else { return nil }
        let file = folder.appendingPathComponent("ghostty-defaults.conf")
        let text = fileText(themesFolder: themesFolder)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            return file.path
        } catch {
            return nil
        }
    }
}
