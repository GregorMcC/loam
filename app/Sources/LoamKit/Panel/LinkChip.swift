import Foundation

extension PlotLink {
    /// The kind chip of a LinkRow (docs/design/components/LinkRow): Notion, Linear, GitHub, URL,
    /// Folder, File, or Vault. A local path with a file extension is a File, any other is a Folder.
    public var chipName: String {
        switch kind {
        case .notion: "Notion"
        case .linear: "Linear"
        case .github: "GitHub"
        case .url: "URL"
        case .vault: "Vault"
        case .path: (target as NSString).pathExtension.isEmpty ? "Folder" : "File"
        }
    }
}
