import AppKit
import LoamKit
import SwiftUI

/// Where a view sits in the window, for a popover that opens from it (ticket 109). Put an
/// `AnchorReader` behind the view, and ask `anchor` in the click handler. The window asks the probe again
/// each time it places the popover, so the popover follows the view.
@MainActor
final class AnchorProbe: PopoverAnchorControl {
    fileprivate(set) weak var view: NSView?

    /// The rectangle of the view in its window, as AppKit reports it. Nil while the view is not in a window,
    /// is hidden, or is out of view: a scroll view or a collapsed column clips all of it.
    var windowRect: CGRect? {
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    /// The anchor of a popover that opens from the view. Without the view, the popover opens from the
    /// action bar, as it does for a key.
    var anchor: PopoverAnchor { windowRect == nil ? .actionBar : .control(self) }
}

/// Fills its place behind a SwiftUI view and tells the `AnchorProbe` which view that is. It takes no clicks.
/// SwiftUI can build more than one copy of a view (`ViewThatFits` does), so the probe follows the copy that is
/// in the window. SwiftUI can also give a copy to another view, such as a reused row of the sidebar, so the
/// copy follows the probe of the view it serves now.
struct AnchorReader: NSViewRepresentable {
    let probe: AnchorProbe

    func makeNSView(context: Context) -> ProbeView { ProbeView(probe: probe) }

    func updateNSView(_ view: ProbeView, context: Context) { view.probe = probe }

    final class ProbeView: NSView {
        fileprivate(set) weak var probe: AnchorProbe? {
            didSet {
                guard probe !== oldValue, window != nil else { return }
                if oldValue?.view === self { oldValue?.view = nil }
                probe?.view = self
            }
        }

        init(probe: AnchorProbe) {
            self.probe = probe
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                probe?.view = self
            } else if probe?.view === self {
                probe?.view = nil
            }
        }
    }
}
