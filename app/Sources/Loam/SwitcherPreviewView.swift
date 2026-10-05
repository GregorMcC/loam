import LoamKit
import SwiftUI

/// A keycap (polish README): a 20 pt square with radius 5, a fill of the ink at about 10%, and 11.5 pt
/// text in `ink-muted`.
struct SwitcherKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(LoamColor.inkMuted)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, text.count > 1 ? 5 : 0)
            .background(LoamColor.ink.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
    }
}

/// The preview column of the switcher: the details of the selected result. The content comes from
/// `SwitcherPreview` in LoamKit. This view only draws it.
struct SwitcherPreviewView: View {
    let preview: SwitcherPreview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let stands = preview.whereItStands {
                    Text("Where it stands")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LoamColor.inkFaint)
                        .padding(.top, 18)
                    Text(stands.isEmpty ? "Not written yet." : stands)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .foregroundStyle(stands.isEmpty ? LoamColor.inkFaint : LoamColor.ink)
                        .padding(.top, 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("switcher-preview-stands")
                }
                if !preview.rows.isEmpty {
                    LoamColor.rule.frame(height: 1).padding(.top, 20)
                    ForEach(Array(preview.rows.enumerated()), id: \.offset) { _, row in
                        metadataRow(row)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("switcher-preview")
    }

    private var header: some View {
        HStack(spacing: 12) {
            LoamIconView(icon: preview.icon, size: 16, color: LoamColor.moss)
                .frame(width: 34, height: 34)
                .background(LoamColor.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LoamColor.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier("switcher-preview-title")
                Text(preview.caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LoamColor.inkMuted)
                    .lineLimit(1)
                    .accessibilityIdentifier("switcher-preview-caption")
            }
        }
    }

    private func metadataRow(_ row: SwitcherPreview.Row) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(row.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(LoamColor.inkFaint)
                    .fixedSize()
                Spacer(minLength: 0)
                value(row.value)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            LoamColor.rule.frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func value(_ value: SwitcherPreview.Value) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(LoamColor.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        case .branch(let name, let branch):
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12.5)).foregroundStyle(LoamColor.ink).lineLimit(1)
                if let branch { chip(branch) }
            }
        case .attention(let attention, let text):
            HStack(spacing: 6) {
                AttentionDot(mark: attention == .needsYou ? .needs : .unread)
                    .frame(width: AttentionDotView.size, height: AttentionDotView.size)
                Text(text).font(.system(size: 12.5)).foregroundStyle(LoamColor.ink).lineLimit(1)
            }
        case .path(let path):
            Text(path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LoamColor.inkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        case .tags(let tags):
            // Pills wrap onto more lines when they do not fit.
            SwitcherWrap(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 12))
                        .foregroundStyle(LoamColor.ink)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(LoamColor.ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .keys(let keys):
            HStack(spacing: 4) { ForEach(Array(keys.enumerated()), id: \.offset) { SwitcherKeycap(text: $1) } }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(LoamColor.inkMuted)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(LoamColor.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The footer of the switcher: 44 pt, a hairline above, and the primary action of the selected result.
struct SwitcherFooter: View {
    let icon: LoamIcon
    let action: String
    let run: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            LoamColor.rule.frame(height: 1)
            HStack(spacing: 8) {
                LoamIconView(icon: icon, size: 13, color: LoamColor.inkMuted)
                Spacer(minLength: 0)
                Button(action: run) {
                    HStack(spacing: 8) {
                        Text(action)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LoamColor.ink)
                        SwitcherKeycap(text: "↵")
                    }
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action)
                .accessibilityIdentifier("switcher-footer-action")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 43)
        }
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("switcher-footer")
    }
}

/// A row of views that wraps to the next line when the width runs out, aligned to the trailing edge.
struct SwitcherWrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map { $0.width }.max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.maxX - line.width
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].indices.isEmpty ? size.width : lines[lines.count - 1].width + spacing + size.width
            if needed > width, !lines[lines.count - 1].indices.isEmpty { lines.append(Line()) }
            let last = lines.count - 1
            lines[last].width = lines[last].indices.isEmpty ? size.width : lines[last].width + spacing + size.width
            lines[last].height = max(lines[last].height, size.height)
            lines[last].indices.append(index)
        }
        return lines
    }
}
