import LoamKit
import SwiftUI

// The stage of a worktree in SwiftUI (ticket 107). The symbol, the colour token and the words of
// each stage come from `WorktreeStage` in LoamKit, so no view holds a copy of the stage table.

extension LoamColor {
    /// The colour of a stage symbol (`WorktreeStage.tone`). It follows the terminal theme like `ink`,
    /// `ink-muted`, `ink-faint` and `rust` do.
    static func stage(_ tone: StageTone) -> Color { ChromeTick.shared.colors[tone.rawValue]! }
}

/// The symbol of a stage at a point size. Not pushed shows the ✎ mark, which is text. No stage shows
/// nothing. `color` is the colour of the stage unless a view gives another.
struct StageGlyph: View {
    let stage: WorktreeStage
    var size: CGFloat = 12
    var color: Color?

    var body: some View {
        let color = color ?? LoamColor.stage(stage.tone)
        if let symbol = stage.symbol {
            LoamIconView(icon: .symbol(symbol), size: size, color: color)
        } else if stage == .notPushed {
            Text("\u{270E}").loamText(LoamTheme.captionStyle, color)
        }
    }
}

/// The trailing mark of a worktree row: the PR number in `ink-muted`, then the stage symbol in the
/// colour of the stage. Work that is not pushed, with no PR, is the ✎ mark alone. The words are for
/// VoiceOver and the driver. The tooltip sits on the row.
struct WorktreeMarkView: View {
    let mark: StageMark

    var body: some View {
        HStack(spacing: 4) {
            if let label = mark.label {
                Text(label)
                    .loamText(LoamTheme.captionStyle, LoamColor.inkMuted)
                    .monospacedDigit()
            }
            StageGlyph(stage: mark.stage)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.spoken)
    }
}
