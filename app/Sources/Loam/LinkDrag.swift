import AppKit
import LoamKit
import SwiftUI

/// Drag to reorder the links of a plot in the panel, as the sidebar reorders plots (`PlotDrag`).
/// A press on a link row and a move of 4 pt starts a drag. The row lifts and follows the pointer,
/// and the other links part to open a gap where it will land (`Reorder`), over `duration-base`
/// with `ease-settle`. A release settles it into the gap and moves the link
/// (`PlotPanelModel.moveLink`). Escape, or a release outside the Links section, sends every row
/// back. Under Reduce Motion nothing slides: the row dims, a `moss` line marks the drop point, and
/// the release moves it at once.
///
/// The links are a `ForEach` in a `VStack`, not rows of a list, so a SwiftUI `offset` moves them
/// without clipping. The drag is a gesture in the view, not a system drag, so the panel's URL drop
/// never sees it and a release cannot add a link.
@MainActor
@Observable
final class LinkDrag {
    /// The coordinate space of the Links section.
    static let space = "panel-links"
    /// A move this far from the press starts a drag. A shorter one is a click.
    static let threshold: CGFloat = 4
    /// The spacing of the Links `VStack`.
    static let spacing: CGFloat = 2

    struct Active {
        let token = UUID()
        let id: String
        /// The link order at the press. A new order makes the geometry stale.
        let order: [String]
        let reorder: Reorder
        let frame: CGRect
        /// True after the release or Escape, while the rows slide to their end.
        var ending = false
        var dragged: Int { reorder.dragged }
    }

    private(set) var active: Active?
    /// Kept apart from `active` so the pointer moves the dragged row at once while the slot
    /// change animates the others.
    private(set) var follow: CGFloat = 0
    private(set) var slot = 0

    /// Row frames and the section bounds, measured in `space`. They only feed the next drag, so
    /// they do not redraw the panel.
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero
    /// Set by Escape until the gesture ends, so the rest of that drag does nothing.
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var escapeMonitor: Any?

    var isActive: Bool { active != nil }

    // MARK: What the rows show

    private func live(_ order: [String]) -> Active? {
        guard let active, active.order == order else { return nil }
        return active
    }

    func offset(of id: String, order: [String]) -> CGFloat {
        guard let active = live(order), let index = order.firstIndex(of: id) else { return 0 }
        if index == active.dragged { return follow }
        if LoamMotion.reduceMotion { return 0 }
        return CGFloat(active.reorder.offset(of: index, slot: slot))
    }

    func isDragged(_ id: String, order: [String]) -> Bool { live(order)?.id == id }

    /// The Reduce Motion line: its frame in `space`, or nil.
    func line(order: [String]) -> CGRect? {
        guard LoamMotion.reduceMotion, let active = live(order),
              let y = active.reorder.insertionPoint(slot: slot) else { return nil }
        return CGRect(x: active.frame.minX, y: CGFloat(y) - 1, width: active.frame.width, height: 2)
    }

    // MARK: The gesture

    func changed(link id: String, order: [String], translation: CGFloat) {
        guard !cancelled else { return }
        if active == nil { begin(link: id, order: order) }
        guard let active, !active.ending, active.order == order else { return }
        let reorder = active.reorder, dragged = active.dragged
        let low = reorder.starts[0] - reorder.starts[dragged]
        let high = (reorder.starts[reorder.count - 1] + reorder.lengths[reorder.count - 1])
            - (reorder.starts[dragged] + reorder.lengths[dragged])
        let shift = min(max(Double(translation), low), high)
        if !LoamMotion.reduceMotion { follow = CGFloat(shift) }
        let next = reorder.slot(start: reorder.starts[dragged] + shift)
        guard next != slot else { return }
        if LoamMotion.reduceMotion {
            slot = next
        } else {
            withAnimation(LoamAnimation.settle) { slot = next }
        }
    }

    /// The release at `location` in `space`. `move` gets the link and its new 1-based position.
    func ended(at location: CGPoint, move: @escaping (String, Int) async -> Void) {
        defer { cancelled = false }
        guard !cancelled, var active, !active.ending else { return }
        removeEscapeMonitor()
        guard bounds.contains(location) else { return cancel() }
        guard slot != active.dragged else { return cancel(LoamAnimation.settle) }
        active.ending = true
        self.active = active
        let (token, id, position) = (active.token, active.id, slot + 1)
        // The rows keep their offsets until the new order shows, then `live` drops them.
        let commit = {
            Task { @MainActor in
                await move(id, position)
                self.reset(token)
            }
        }
        if LoamMotion.reduceMotion { _ = commit(); return }
        let settle = CGFloat(active.reorder.settleOffset(slot: slot))
        withAnimation(LoamAnimation.settle) { follow = settle } completion: { _ = commit() }
    }

    /// Escape, or a release outside the section: every row slides back over `duration-slow`.
    func cancel(_ animation: Animation = LoamAnimation.arrive) {
        guard var active, !active.ending else { return }
        active.ending = true
        self.active = active
        removeEscapeMonitor()
        let token = active.token
        if LoamMotion.reduceMotion { return reset(token) }
        withAnimation(animation) {
            follow = 0
            slot = active.dragged
        } completion: { self.reset(token) }
    }

    /// The gesture is gone, ended or cancelled by SwiftUI with no `ended`: send the rows back.
    func gestureGone() {
        cancelled = false
        cancel()
    }

    /// The Links section left the panel: drop the drag at once.
    func abandon() {
        cancelled = false
        if let active { reset(active.token) }
    }

    /// The link order changed under the drag, say by a reload: the geometry is stale.
    func orderChanged(_ order: [String]) {
        guard let active, !active.ending, active.order != order else { return }
        reset(active.token)
    }

    private func begin(link id: String, order: [String]) {
        guard order.count > 1, let dragged = order.firstIndex(of: id) else { return }
        let rects = order.compactMap { frames[$0] }
        guard rects.count == order.count else { return }
        let reorder = Reorder(starts: rects.map { Double($0.minY) }, lengths: rects.map { Double($0.height) },
                              spacing: Double(Self.spacing), dragged: dragged)
        follow = 0
        slot = dragged
        active = Active(id: id, order: order, reorder: reorder, frame: rects[dragged])
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.active?.ending == false else { return event }
            self.cancelled = true
            self.cancel()
            return nil
        }
    }

    private func reset(_ token: UUID) {
        guard active?.token == token else { return }
        removeEscapeMonitor()
        active = nil
        follow = 0
        slot = 0
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

extension View {
    /// The lift under a dragged link row: the raised fill with a soft shadow, as `PlotDrag`'s card.
    @ViewBuilder func linkDragLift(_ lifted: Bool) -> some View {
        background {
            if lifted {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LoamColor.horizonB)
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            }
        }
    }
}
