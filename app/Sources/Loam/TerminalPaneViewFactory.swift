#if canImport(GhosttyKit)
import AppKit
import LoamKit
import LoamTerminal
import OSLog

/// Gives each pane a libghostty terminal surface and its pane socket, and closes both with the safe order.
@MainActor
final class TerminalPaneViewFactory: PaneViewFactory {
    let runtime: TerminalRuntime
    let sockets: PaneSocketFolder
    /// libghostty asks to close a pane, for example after its shell exits.
    var onCloseRequest: ((PaneID) -> Void)?
    /// The terminal title of a pane changed. The quick switcher matches on it.
    var onTitleChange: ((PaneID, String) -> Void)?
    /// A line from a pane's socket, on the main actor.
    var onPaneEvent: ((PaneID, PaneEvent) -> Void)?
    /// A pane's process exited.
    var onChildExited: ((PaneID) -> Void)?
    /// You typed in a pane.
    var onKeyInput: ((PaneID) -> Void)?

    /// Each live view: its pane, its launch token, and its socket.
    private var views: [ObjectIdentifier: (pane: PaneID, launch: UUID, server: PaneSocketServer?)] = [:]
    /// The launch token of the newest view of each pane.
    private var launches: [PaneID: UUID] = [:]

    init(runtime: TerminalRuntime, sockets: PaneSocketFolder = PaneSocketFolder()) {
        self.runtime = runtime
        self.sockets = sockets
    }

    func makeView(for spec: PaneSpec, id: PaneID) -> NSView {
        var spec = spec
        // A restarted pane keeps its ID. Only the newest view of a pane may report for it.
        let launch = UUID()
        launches[id] = launch
        let current = { [weak self] in self?.launches[id] == launch }
        // The socket comes first, so the pane's env can name it (docs/contract.md, "Pane socket").
        // A pane with no socket still runs. Its session only raises no state.
        let server: PaneSocketServer?
        do {
            server = try PaneSocketServer(path: try sockets.makePath()) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.launches[id] == launch else { return }
                    self.onPaneEvent?(id, event)
                }
            }
            spec.env["LOAM_PANE_SOCKET"] = server?.path
        } catch {
            server = nil
            paneLog.error("No pane socket for \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        do {
            let view = try TerminalSurfaceView(runtime: runtime, spec: spec)
            // A seeded pane stays after its session ends and shows its own "Session ended" bar.
            let seeded = spec.kind == .session
            view.replacesExitMessage = seeded
            view.onChildExited = { [weak self] _ in if current() { self?.onChildExited?(id) } }
            view.onCloseRequest = { [weak self] processAlive in
                if seeded, !processAlive { return }
                if current() { self?.onCloseRequest?(id) }
            }
            view.onTitleChange = { [weak self] title in if current() { self?.onTitleChange?(id, title) } }
            view.onKeyInput = { [weak self] in if current() { self?.onKeyInput?(id) } }
            views[ObjectIdentifier(view)] = (id, launch, server)
            return view
        } catch {
            server?.close()
            var failed = spec
            failed.title = "The terminal did not start"
            return PlaceholderPaneView(spec: failed)
        }
    }

    func closeView(_ view: NSView, completion: @escaping @MainActor () -> Void) {
        // The socket closes after the process, so the session's last hooks still reach it.
        let entry = views.removeValue(forKey: ObjectIdentifier(view))
        if let entry, launches[entry.pane] == entry.launch { launches[entry.pane] = nil }
        let server = entry?.server
        guard let surface = view as? TerminalSurfaceView else { server?.close(); return completion() }
        surface.close { _ in
            server?.close()
            completion()
        }
    }

    /// Sends each pane's socket lines, process exit, and close request to the model.
    func connect(to model: AppModel) {
        onCloseRequest = { [weak model] in model?.closePane($0) }
        onPaneEvent = { [weak model] in model?.apply($1, to: $0) }
        onChildExited = { [weak model] in model?.paneExited($0) }
        onTitleChange = { [weak model] pane, title in model?.setTerminalTitle(title, of: pane) }
        onKeyInput = { [weak model] in model?.typed(in: $0) }
    }

    /// Removes every socket. The app calls it at quit.
    func closeAllSockets() {
        views.values.forEach { $0.server?.close() }
        views = [:]
        sockets.removeAll()
    }
}

private let paneLog = Logger(subsystem: "dev.loam.Loam", category: "panes")
#endif
