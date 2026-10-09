import AppKit
import LoamKit
import QuartzCore
import SwiftUI

/// Drag to reorder plots in the sidebar (ticket 98), as the Finder sidebar does. A press on a plot
/// row and a move of 4 pt starts a drag. The plot, with its whole tree when it is open, follows the
/// pointer up and down its section on a lifted card. The other plots of the section part to open a
/// gap where it will land (`Reorder`), over `duration-base` with `ease-settle`. A release settles
/// it into the gap and moves the plot (`AppModel.showPlotMove`, then `loam move`). Escape, or a
/// release outside the sidebar, sends every row back. Under Reduce Motion nothing slides: the plot
/// dims, a `moss` line marks the drop point, and the release moves it at once.
///
/// SwiftUI cannot move list rows apart: a row that grows does not animate, and an offset is
/// clipped by the row. So the drag moves the row views of the sidebar's outline view with layer
/// transforms, and Core Animation runs the slides.
@MainActor
final class PlotDragController {
    private let model: AppModel
    /// The plot under the press, the handle that took it, and the point in the window.
    private var press: (plot: String, handle: NSView, point: CGPoint)?
    private var drag: Drag?
    private var escapeMonitor: Any?

    init(model: AppModel) { self.model = model }

    /// A move this far from the press starts a drag. A shorter one is a click.
    static let threshold: CGFloat = 4

    private struct Block {
        var rows: [NSView]
    }

    private struct Drag {
        let plot: String
        let outline: NSOutlineView
        let reorder: Reorder
        let blocks: [Block]
        /// The plot order, the row count and the scroll at the press. A change to any of them makes
        /// the geometry stale, so the drag ends.
        let plots: [String]
        let rowCount: Int
        let visible: CGRect
        let startY: CGFloat
        var slot: Int
        var follow: CGFloat = 0
        /// True after the release or Escape, while the rows slide to their end.
        var ending = false
        /// The lifted card under the dragged rows, and the line for Reduce Motion.
        let card: CALayer
        let line: CALayer
        var dragged: Int { reorder.dragged }
    }

    // MARK: Input from the handle

    func mouseDown(plot: String, handle: NSView, event: NSEvent) {
        guard drag == nil else { return }
        press = (plot, handle, event.locationInWindow)
    }

    func mouseDragged(event: NSEvent) {
        let point = event.locationInWindow
        if drag == nil, let press, hypot(point.x - press.point.x, point.y - press.point.y) >= Self.threshold {
            begin(plot: press.plot, handle: press.handle, at: press.point)
        }
        guard drag != nil else { return }
        move(to: point)
    }

    /// Returns true when the release was a click: no drag started.
    func mouseUp(event: NSEvent) -> Bool {
        defer { press = nil }
        guard let drag else { return press != nil }
        guard !drag.ending else { return false }
        guard let scroll = drag.outline.enclosingScrollView else { cancel(); return false }
        let inside = scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
        if inside { drop() } else { cancel() }
        return false
    }

    // MARK: The drag

    private func begin(plot: String, handle: NSView, at windowPoint: CGPoint) {
        // One move at a time: the last one may still wait on `loam move`.
        guard !model.isMovingPlot, let outline = Self.outline(holding: handle),
              let section = model.sidebar.section(of: plot) else { return }
        let row = outline.row(for: handle)
        guard row >= 0 else { return }
        // The section: the rows around this one at its level or deeper. A plot row is at the level
        // of this row. The rows under it, up to the next plot row, are its tree.
        let level = outline.level(forRow: row)
        var first = row, last = row
        while first > 0, outline.level(forRow: first - 1) >= level { first -= 1 }
        while last < outline.numberOfRows - 1, outline.level(forRow: last + 1) >= level { last += 1 }
        let plotRows = (first...last).filter { outline.level(forRow: $0) == level }
        let ids = model.sidebar.plotIDs(in: section)
        guard plotRows.count == ids.count, let dragged = ids.firstIndex(of: plot), plotRows[dragged] == row,
              plotRows.count > 1 else { return }
        var blocks: [Block] = []
        var starts: [Double] = [], lengths: [Double] = []
        for (index, start) in plotRows.enumerated() {
            let end = index + 1 < plotRows.count ? plotRows[index + 1] - 1 : last
            let top = outline.rect(ofRow: start).minY, bottom = outline.rect(ofRow: end).maxY
            starts.append(Double(top))
            lengths.append(Double(bottom - top))
            blocks.append(Block(rows: (start...end).compactMap { outline.rowView(atRow: $0, makeIfNecessary: false) }))
        }
        guard let host = outline.layer else { return }
        let reorder = Reorder(starts: starts, lengths: lengths, dragged: dragged)
        let card = Self.card(for: outline, top: starts[dragged], height: lengths[dragged])
        let line = CALayer()
        line.backgroundColor = LoamTheme.moss.cgColor
        line.cornerRadius = 1
        line.isHidden = true
        line.zPosition = 20
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(card)
        host.addSublayer(line)
        for view in blocks[dragged].rows {
            view.wantsLayer = true
            view.layer?.zPosition = 10
            if LoamMotion.reduceMotion { view.alphaValue = 0.5 }
        }
        card.isHidden = LoamMotion.reduceMotion
        CATransaction.commit()
        // The press is now a drag, so its release is never a click.
        press = nil
        drag = Drag(plot: plot, outline: outline, reorder: reorder, blocks: blocks, plots: model.plots.map(\.id),
                    rowCount: outline.numberOfRows, visible: outline.visibleRect,
                    startY: outline.convert(windowPoint, from: nil).y, slot: dragged, card: card, line: line)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag?.ending == false else { return event }
            self.cancel()
            return nil
        }
    }

    private func move(to windowPoint: CGPoint) {
        guard var drag, !drag.ending else { return }
        let outline = drag.outline
        // A sidebar update that adds or removes rows, a new plot order, or a scroll ends the drag.
        guard outline.numberOfRows == drag.rowCount, outline.visibleRect == drag.visible,
              model.plots.map(\.id) == drag.plots else { return finish() }
        let y = outline.convert(windowPoint, from: nil).y
        let reorder = drag.reorder
        let reduce = LoamMotion.reduceMotion
        let low = reorder.starts[0] - reorder.starts[drag.dragged]
        let high = (reorder.starts[reorder.count - 1] + reorder.lengths[reorder.count - 1])
            - (reorder.starts[drag.dragged] + reorder.lengths[drag.dragged])
        // Where the plot would be. Under Reduce Motion it stays in place, but the slot still follows.
        let shift = min(max(Double(y - drag.startY), low), high)
        drag.follow = reduce ? 0 : CGFloat(shift)
        Self.place(drag.blocks[drag.dragged].rows + [drag.card], at: drag.follow, duration: 0)
        let slot = reorder.slot(start: reorder.starts[drag.dragged] + shift)
        if slot != drag.slot {
            drag.slot = slot
            if !reduce {
                for index in drag.blocks.indices where index != drag.dragged {
                    Self.place(drag.blocks[index].rows, at: CGFloat(reorder.offset(of: index, slot: slot)),
                               duration: LoamTheme.durationBase)
                }
            }
        }
        if reduce { showLine(&drag) }
        self.drag = drag
    }

    /// Under Reduce Motion: a 2 pt line across the row at the drop point.
    private func showLine(_ drag: inout Drag) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let y = drag.reorder.insertionPoint(slot: drag.slot) {
            drag.line.frame = CGRect(x: 10, y: CGFloat(y) - 1, width: drag.outline.bounds.width - 20, height: 2)
            drag.line.isHidden = false
        } else {
            drag.line.isHidden = true
        }
        CATransaction.commit()
    }

    /// The release: the plot settles into its gap over `duration-base`, then the order changes.
    private func drop() {
        guard var drag else { return }
        drag.ending = true
        self.drag = drag
        guard drag.slot != drag.dragged else { return cancel(duration: LoamTheme.durationBase) }
        if LoamMotion.reduceMotion { return commit() }
        removeEscapeMonitor()
        let offset = CGFloat(drag.reorder.settleOffset(slot: drag.slot))
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.commit() }
        }
        Self.place(drag.blocks[drag.dragged].rows + [drag.card], at: offset, duration: LoamTheme.durationBase)
        CATransaction.commit()
    }

    /// Escape or a release outside the sidebar: every row slides back over `duration-slow`.
    private func cancel(duration: TimeInterval = LoamTheme.durationSlow) {
        guard var drag else { return }
        drag.ending = true
        self.drag = drag
        removeEscapeMonitor()
        guard !LoamMotion.reduceMotion else { return finish() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        for block in drag.blocks { Self.place(block.rows, at: 0, duration: duration) }
        Self.place([drag.card], at: 0, duration: duration)
        CATransaction.commit()
    }

    /// The sidebar takes the new order now, and the rows lose their offsets in the same frame.
    /// Then `loam move` runs.
    private func commit() {
        guard let drag else { return }
        let move = model.showPlotMove(drag.plot, toSlot: drag.slot)
        // Let SwiftUI lay out the list in the new order before the offsets go, so no frame shows
        // the rows twice moved.
        drag.outline.window?.contentView?.layoutSubtreeIfNeeded()
        finish()
        if let move { Task { await model.storePlotMove(move) } }
    }

    private func finish() {
        guard let drag else { return }
        removeEscapeMonitor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for block in drag.blocks {
            for view in block.rows {
                view.layer?.removeAnimation(forKey: "reorder")
                view.layer?.transform = CATransform3DIdentity
                view.layer?.zPosition = 0
                view.alphaValue = 1
            }
        }
        drag.card.removeFromSuperlayer()
        drag.line.removeFromSuperlayer()
        CATransaction.commit()
        self.drag = nil
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: Layers

    /// Moves each layer down by `offset`, from where it shows now, with `ease-settle`.
    private static func place(_ items: [AnyObject], at offset: CGFloat, duration: TimeInterval) {
        let target = CATransform3DMakeTranslation(0, offset, 0)
        for item in items {
            guard let layer = (item as? NSView)?.layer ?? (item as? CALayer) else { continue }
            let from = layer.presentation()?.transform ?? layer.transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = target
            CATransaction.commit()
            guard duration > 0, !CATransform3DEqualToTransform(from, target) else {
                layer.removeAnimation(forKey: "reorder")
                continue
            }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: from)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = duration
            animation.timingFunction = LoamMotion.timingFunction(LoamTheme.easeSettle)
            layer.add(animation, forKey: "reorder")
        }
    }

    /// The lift under the dragged rows: the selected row fill on the sidebar ground, radius 7, with
    /// a soft shadow, so the rows it passes do not show through.
    private static func card(for outline: NSOutlineView, top: Double, height: Double) -> CALayer {
        let card = CALayer()
        card.frame = CGRect(x: 8, y: CGFloat(top), width: outline.bounds.width - 16, height: CGFloat(height))
        card.cornerRadius = 7
        outline.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = LoamTheme.horizonB.cgColor
        }
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.22
        card.shadowRadius = 6
        card.shadowOffset = CGSize(width: 0, height: outline.isFlipped ? 2 : -2)
        card.zPosition = 9
        return card
    }

    private static func outline(holding view: NSView) -> NSOutlineView? {
        var current = view.superview
        while let next = current {
            if let outline = next as? NSOutlineView { return outline }
            current = next.superview
        }
        return nil
    }
}

/// The AppKit view over a plot row that takes the press (ticket 98). A click selects the plot. A
/// move of 4 pt drags it. A right click goes on to the list, which shows the row menu.
final class PlotDragHandleView: NSView {
    var plot = ""
    weak var controller: PlotDragController?
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(plot: plot, handle: self, event: event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event: event) }
    override func mouseUp(with event: NSEvent) {
        if controller?.mouseUp(event: event) == true { onClick?() }
    }
}

/// The SwiftUI side of `PlotDragHandleView`. The driver finds it by its identifier, `plot-drag-<plot ID>`.
struct PlotDragHandle: NSViewRepresentable {
    let plot: String
    let controller: PlotDragController
    let onClick: () -> Void

    func makeNSView(context: Context) -> PlotDragHandleView {
        let view = PlotDragHandleView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ view: PlotDragHandleView, context: Context) { update(view) }

    private func update(_ view: PlotDragHandleView) {
        view.plot = plot
        view.controller = controller
        view.onClick = onClick
        view.identifier = NSUserInterfaceItemIdentifier("plot-drag-\(plot)")
    }
}
