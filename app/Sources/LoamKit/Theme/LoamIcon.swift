import Foundation

/// The icon of a thing in the app (docs/design, Iconography): an SF Symbol, or a third-party mark
/// for the service that a link or a pane belongs to.
public enum LoamIcon: Equatable, Sendable {
    case symbol(String)
    case brand(BrandMark)

    public static let plot = LoamIcon.symbol("square.stack.3d.down.right")
    public static let shell = LoamIcon.symbol("terminal")
    /// A Claude session pane.
    public static let session = LoamIcon.brand(.claude)
    public static let action = LoamIcon.symbol("command")

    /// The icon of a pane of this kind.
    public static func pane(_ kind: PaneSpec.Kind) -> LoamIcon {
        kind == .session ? session : shell
    }

    /// The icon of a link of this kind. A URL on claude.ai takes the Claude mark.
    public static func link(_ kind: LinkKind, target: String) -> LoamIcon {
        switch kind {
        case .github: .brand(.github)
        case .linear: .brand(.linear)
        case .notion: .symbol("doc.richtext")
        case .vault: .symbol("doc.text")
        case .url:
            URL(string: target)?.host().map { $0 == "claude.ai" || $0.hasSuffix(".claude.ai") } == true
                ? .brand(.claude) : .symbol("link")
        case .path: (target as NSString).pathExtension.isEmpty ? .symbol("folder") : .symbol("doc")
        }
    }
}

extension PlotLink {
    public var icon: LoamIcon { .link(kind, target: target) }
}
