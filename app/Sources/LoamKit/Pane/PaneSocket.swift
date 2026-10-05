import Darwin
import Foundation
import OSLog

extension PaneEvent {
    /// The events in a chunk of pane socket text: one JSON object per line. A line that is not
    /// a pane event is skipped, so a later version of the core can add events and fields
    /// (docs/contract.md, "Pane socket").
    public static func lines(in data: Data) -> [PaneEvent] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(PaneEvent.self, from: Data(line))
        }
    }
}

/// The Unix socket of one pane. `loam hook` connects, writes one line, and closes. The server
/// reads lines until each connection closes and calls `onEvent` for each event, on its own queue.
/// The socket file is readable and writable by you only. `close()` removes it.
public final class PaneSocketServer: @unchecked Sendable {
    public enum SocketError: Error, Equatable {
        /// The path does not fit in a Unix socket address (104 bytes on macOS).
        case pathTooLong(String)
        case system(String, Int32)
    }

    public let path: String
    /// A connection that sends more than this without a newline is dropped.
    static let maxLineBytes = 64 * 1024

    /// `accept()` on the listening socket: the new socket, or -1 and the error number.
    typealias Accept = @Sendable (_ listener: Int32) -> (client: Int32, error: Int32)

    /// The timing of the server, and the `accept` call. Tests change them.
    struct Options: Sendable {
        /// A connection that is still open this long after it connected ends as if the writer closed
        /// it: a last line with no newline counts, then the server closes it. `loam hook`
        /// writes one line in under 200 ms, so only a hung writer gets here.
        var readTimeout: DispatchTimeInterval = .seconds(5)
        /// After an `accept` error other than "no connection waiting" (for example `EMFILE`),
        /// the server stops accepting for this long. Without the pause, the waiting connection
        /// wakes the queue again at once, and the queue uses 100% CPU.
        var acceptPause: DispatchTimeInterval = .milliseconds(250)
        var accept: Accept = { listener in
            let client = Darwin.accept(listener, nil, nil)
            return (client, client < 0 ? errno : 0)
        }
    }

    private let options: Options
    private let queue = DispatchQueue(label: "dev.loam.pane-socket")
    /// Set on this server's queue only. Each server has its own key, so a call from another
    /// server's queue does not count as "on my queue".
    private let onQueue = DispatchSpecificKey<Bool>()
    private let onEvent: @Sendable (PaneEvent) -> Void
    // Touched only on `queue`.
    private var listener: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var closed = false
    /// The listener is suspended after an `accept` error.
    private var acceptPaused = false
    /// The error is logged once, until an `accept` works again.
    private var acceptErrorLogged = false

    private struct Client {
        var source: DispatchSourceRead
        var timer: DispatchSourceTimer
        var buffer = Data()

        func cancel() {
            timer.cancel()
            source.cancel()
        }
    }

    public convenience init(path: String, onEvent: @escaping @Sendable (PaneEvent) -> Void) throws {
        try self.init(path: path, options: Options(), onEvent: onEvent)
    }

    init(path: String, options: Options, onEvent: @escaping @Sendable (PaneEvent) -> Void) throws {
        self.path = path
        self.options = options
        self.onEvent = onEvent
        queue.setSpecific(key: onQueue, value: true)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        func fail(_ call: String) -> SocketError {
            let code = errno
            Darwin.close(fd)
            return .system(call, code)
        }
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw fail("bind") }
        guard chmod(path, 0o600) == 0 else { throw fail("chmod") }
        guard listen(fd, 64) == 0 else { throw fail("listen") }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw fail("fcntl") }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    deinit { close() }

    /// Stops listening, drops open connections, and removes the socket file. A second call does nothing.
    public func close() {
        // The last reference can go away inside an event handler, on the queue itself.
        if DispatchQueue.getSpecific(key: onQueue) != nil { closeOnQueue() } else { queue.sync(execute: closeOnQueue) }
    }

    private func closeOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        closed = true
        if let listener {
            listener.cancel()
            // A suspended source never runs its cancel handler, and its release crashes.
            if acceptPaused { listener.resume() }
        }
        listener = nil
        for (_, client) in clients { client.cancel() }
        clients = [:]
        unlink(path)
    }

    private func acceptAll(_ fd: Int32) {
        while true {
            let (client, error) = options.accept(fd)
            if client < 0 {
                switch error {
                case EAGAIN, EWOULDBLOCK: return  // No more waiting connections.
                case EINTR, ECONNABORTED: continue
                default: return pauseAccepting(error)
                }
            }
            acceptErrorLogged = false
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            source.setEventHandler { [weak self] in self?.read(client) }
            source.setCancelHandler { Darwin.close(client) }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + options.readTimeout)
            timer.setEventHandler { [weak self] in self?.timedOut(client) }
            clients[client] = Client(source: source, timer: timer)
            source.resume()
            timer.resume()
        }
    }

    /// An `accept` error that waiting does not fix at once, such as `EMFILE` (too many open
    /// files). The listener stops for `acceptPause`, then tries again.
    private func pauseAccepting(_ error: Int32) {
        guard let listener, !acceptPaused else { return }
        if !acceptErrorLogged {
            acceptErrorLogged = true
            socketLog.error("Pane socket \(self.path, privacy: .public): accept failed with errno \(error). Loam tries again.")
        }
        acceptPaused = true
        listener.suspend()
        queue.asyncAfter(deadline: .now() + options.acceptPause) { [weak self] in
            guard let self, self.acceptPaused, !self.closed else { return }
            self.acceptPaused = false
            self.listener?.resume()
        }
    }

    /// The read timeout of a connection: it ends as if the writer closed it.
    private func timedOut(_ client: Int32) {
        guard clients[client] != nil else { return }
        deliverLines(client, final: true)
        clients.removeValue(forKey: client)?.cancel()
    }

    private func read(_ client: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &chunk, chunk.count)
            if count > 0 {
                clients[client]?.buffer.append(contentsOf: chunk[0..<count])
                deliverLines(client, final: false)
                // A connection that sent too much is gone. Stop reading it now, not at its end.
                if clients[client] == nil { return }
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // End of the connection (0) or an error: deliver what is left, then drop it.
            deliverLines(client, final: true)
            clients.removeValue(forKey: client)?.cancel()
            return
        }
    }

    /// Delivers each complete line. At the end of a connection, a last line with no newline counts too.
    private func deliverLines(_ client: Int32, final: Bool) {
        guard var buffer = clients[client]?.buffer else { return }
        var complete = Data()
        if final {
            swap(&complete, &buffer)
        } else if let last = buffer.lastIndex(of: UInt8(ascii: "\n")) {
            complete = buffer[..<buffer.index(after: last)]
            buffer = Data(buffer[buffer.index(after: last)...])
        }
        if buffer.count > Self.maxLineBytes {
            buffer = Data()
            clients.removeValue(forKey: client)?.cancel()
        } else if clients[client] != nil {
            clients[client]?.buffer = buffer
        }
        for event in PaneEvent.lines(in: complete) { onEvent(event) }
    }
}

private let socketLog = Logger(subsystem: "dev.loam.Loam", category: "pane-socket")

/// Hands out a short socket path per pane, in a private folder of the app's temp folder, and
/// removes the folder at quit. A Unix socket path must stay under 104 bytes.
public final class PaneSocketFolder: @unchecked Sendable {
    public let folder: URL
    private var next = 0
    private let lock = NSLock()

    /// `base` is the temp folder by default. The folder name holds the process ID, so two apps never share it.
    public init(base: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        folder = base.appendingPathComponent("loam-\(getpid())", isDirectory: true)
    }

    /// A new path. Makes the folder, readable by you only, on first use.
    public func makePath() throws -> String {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let n = lock.withLock { next += 1; return next }
        return folder.appendingPathComponent("p\(n).sock").path
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
