import AppKit
import LoamKit
import SwiftUI

// The Loam design system in SwiftUI (docs/design). Every value comes from `LoamTheme`, which
// scripts/gen-loam-theme.py generates from docs/design/tokens.json. A new view takes colors,
// type, spacing, and motion from here. Controls are native (tickets 71 and 72) and take their
// colors from `LoamColor`.

/// The theme colors for SwiftUI (tickets 68 and 70): the surfaces, the ink, and the state hues that
/// follow the terminal (`ChromeSurfaces.tokenNames`). It is the one way that SwiftUI reads the
/// palette: read `LoamColor.*`. A bump after a `ChromePalette.shared` change makes new colors, and
/// the Observation framework draws each view that read one again.
@MainActor @Observable
final class ChromeTick {
    static let shared = ChromeTick()
    private(set) var colors: [String: Color] = ChromeTick.make()

    func bump() { colors = Self.make() }

    /// New NSColor objects: SwiftUI keeps a color that compares equal to the last one.
    private static func make() -> [String: Color] {
        var colors: [String: Color] = [:]
        for token in LoamTheme.colorTokens where ChromeSurfaces.tokenNames.contains(token.name) {
            colors[token.name] = Color(nsColor: LoamTheme.surface(token.name, night: token.night, day: token.day))
        }
        // The one ground around the well. A new color on each bump, so SwiftUI redraws with it.
        colors["chrome"] = Color(nsColor: LoamTheme.chrome())
        return colors
    }
}

/// The color tokens as SwiftUI colors. Each one follows the appearance: Night for dark, Day for light.
/// The surfaces also follow the terminal theme (`ChromePalette`).
@MainActor
enum LoamColor {
    static var bedrock: Color { ChromeTick.shared.colors["bedrock"]! }
    static var horizonO: Color { ChromeTick.shared.colors["horizon-o"]! }
    static var horizonA: Color { ChromeTick.shared.colors["horizon-a"]! }
    static var horizonB: Color { ChromeTick.shared.colors["horizon-b"]! }
    static var rule: Color { ChromeTick.shared.colors["rule"]! }
    /// The ground behind the glass sidebar and the toolbar row.
    static var frame: Color { ChromeTick.shared.colors["frame"]! }
    /// The ground around the well (`LoamTheme.chrome`): `horizon-a` in Night, `horizon-o` in Day.
    static var chrome: Color { ChromeTick.shared.colors["chrome"]! }
    /// The plot panel's ground: `chrome` at the window alpha (`background-opacity`), as
    /// `LoamTheme.ground` gives the AppKit grounds, so the panel, the toolbar row, the margin of
    /// the well and the action bar read as one frame. `ChromeTick` bumps when the opacity changes.
    static var panelGround: Color { chrome.opacity(ChromePalette.shared.windowOpacity) }
    static let edge = Color(nsColor: LoamTheme.edge)
    static var ink: Color { ChromeTick.shared.colors["ink"]! }
    // Neutral fills and hairlines mix from the derived ink (polish prototype, ticket 86), so they
    // follow the terminal theme and take no fixed hex.
    /// A field at rest and a hovered row: the ink at 5%.
    static var inkFill: Color { ink.opacity(0.05) }
    /// The selected row: the ink at 9%.
    static var inkSelected: Color { ink.opacity(0.09) }
    /// A keycap: the ink at 10%.
    static var inkKey: Color { ink.opacity(0.10) }
    /// A soft hairline: the ink at 8%.
    static var inkHairline: Color { ink.opacity(0.08) }
    static var inkMuted: Color { ChromeTick.shared.colors["ink-muted"]! }
    static var inkFaint: Color { ChromeTick.shared.colors["ink-faint"]! }
    static var moss: Color { ChromeTick.shared.colors["moss"]! }
    static let onMoss = Color(nsColor: LoamTheme.onMoss)
    static let mossWash = Color(nsColor: LoamTheme.mossWash)
    static var needsYou: Color { ChromeTick.shared.colors["needs-you"]! }
    static let needsYouWash = Color(nsColor: LoamTheme.needsYouWash)
    static var doneUnread: Color { ChromeTick.shared.colors["done-unread"]! }
    static var rust: Color { ChromeTick.shared.colors["rust"]! }
    static let rustWash = Color(nsColor: LoamTheme.rustWash)
}

// MARK: Type

extension View {
    /// Applies a type style: face, size, weight, tracking, and line height.
    func loamText(_ style: LoamTheme.TypeStyle, _ color: Color = LoamColor.ink) -> some View {
        font(Font(LoamTheme.font(style)))
            .tracking(style.tracking * style.size)
            .lineSpacing(LoamTheme.lineSpacing(style))
            .foregroundStyle(color)
    }

    /// A section label: uppercase, tracked, in `ink-faint`.
    func loamLabel() -> some View {
        loamText(LoamTheme.labelStyle, LoamColor.inkFaint).textCase(.uppercase)
    }
}

// MARK: Motion

/// Animations from the duration and easing tokens. Under Reduce Motion each one is a short
/// linear fade, so only the color changes.
enum LoamAnimation {
    private static func curve(_ easing: LoamTheme.Easing, _ duration: TimeInterval) -> Animation {
        .timingCurve(Double(easing.x1), Double(easing.y1), Double(easing.x2), Double(easing.y2), duration: duration)
    }

    /// Hover and press.
    static var fast: Animation { .linear(duration: LoamTheme.durationFast) }
    /// Things that arrive, for example a selected row: `duration-base`, `ease-settle`.
    static var settle: Animation {
        LoamMotion.reduceMotion ? fast : curve(LoamTheme.easeSettle, LoamTheme.durationBase)
    }
    /// A new change row, a sheet in: `duration-slow`, `ease-settle`.
    static var arrive: Animation {
        LoamMotion.reduceMotion ? fast : curve(LoamTheme.easeSettle, LoamTheme.durationSlow)
    }
    /// Things that leave: `ease-lift`.
    static var lift: Animation {
        LoamMotion.reduceMotion ? fast : curve(LoamTheme.easeLift, LoamTheme.durationBase)
    }

    /// A new change row grows in from nothing. Under Reduce Motion it fades only.
    static var growIn: AnyTransition {
        LoamMotion.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

// MARK: Surfaces

extension View {
    /// A card on a surface: a ground, a `rule` hairline, and a radius. For popovers and sheets use
    /// `loamFloating()`.
    func loamCard(_ ground: Color = LoamColor.horizonB, radius: CGFloat = LoamTheme.radiusMd) -> some View {
        background(ground, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LoamColor.rule))
    }

    /// A sheet that floats over the panes: `horizon-b`, `radius-lg`, `shadow-switcher`.
    func loamFloating() -> some View {
        loamCard(LoamColor.horizonB, radius: LoamTheme.radiusLg)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}

// MARK: Attention

/// The attention dot (docs/design/components/AttentionDot): an AppKit view with the halo.
struct AttentionDot: NSViewRepresentable {
    var mark: AttentionMark
    var isArriving = false
    var paneFocused = false
    /// 8 px in a row, 6 px in the count badge.
    var size: CGFloat = AttentionDotView.size

    func makeNSView(context: Context) -> AttentionDotView {
        let view = AttentionDotView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ view: AttentionDotView, context: Context) { update(view) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AttentionDotView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    private func update(_ view: AttentionDotView) {
        view.mark = mark
        view.paneFocused = paneFocused
        view.isArriving = isArriving
    }
}

/// The count badge: panes that need you, on a sidebar row. Show it only for Needs you.
/// Its dot plays the halo when a pane of the plot starts to need you.
struct NeedsYouBadge: View {
    let count: Int
    var isArriving = false

    var body: some View {
        HStack(spacing: LoamTheme.space1) {
            AttentionDot(mark: .needs, isArriving: isArriving, size: 6)
                .frame(width: 6, height: 6)
            Text("\(count)").monospacedDigit()
        }
        .font(Font(NSFont.systemFont(ofSize: 11, weight: LoamTheme.fontWeight(650))))
        .foregroundStyle(LoamColor.needsYou)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(LoamColor.needsYouWash, in: Capsule())
        .fixedSize()  // The count never truncates.
    }
}

/// A neutral count chip. Amber is for Needs you only, so other counts use this.
struct CountChip: View {
    let text: String
    var body: some View {
        Text(text)
            .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
            .monospacedDigit()
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(LoamColor.horizonB, in: Capsule())
    }
}

// MARK: Buttons

extension View {
    /// The one primary button of a row, such as Save or Add: a native prominent button in `moss`
    /// with `on-moss` text. Other buttons stay native and untinted.
    func loamPrimaryButton() -> some View { modifier(LoamPrimaryButton()) }
}

/// A prominent button draws in its tint only in the key window. In other windows it draws as a
/// plain bordered button, so it keeps the system text color there.
private struct LoamPrimaryButton: ViewModifier {
    @Environment(\.controlActiveState) private var state

    func body(content: Content) -> some View {
        let tinted = content.buttonStyle(.borderedProminent).tint(LoamColor.moss)
        if state == .key {
            tinted.foregroundStyle(LoamColor.onMoss)
        } else {
            tinted
        }
    }
}

// MARK: Icons

/// A `LoamIcon` at a point size, tinted like an SF Symbol (docs/design, Iconography). A symbol is
/// medium weight. A third-party mark is one colour, unaltered, in a square a little smaller than
/// the symbol's line, so the two read at the same weight.
struct LoamIconView: View {
    let icon: LoamIcon
    var size: CGFloat = 12
    var color: Color = LoamColor.inkMuted

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: size, weight: .medium))
            case .brand(let mark):
                Image(nsImage: mark.image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.05, height: size * 1.05)
                    .accessibilityLabel(mark.name)
            }
        }
        .foregroundStyle(color)
    }
}

/// A keycap (polish README): a 20 pt square, radius 5, the ink at 10%, 11.5 pt text in `ink-muted`.
struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(LoamColor.inkMuted)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 1)
            .background(LoamColor.inkKey, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}
