import Darwin
import Foundation
import Testing

@testable import LoamKit

/// The events that a server got, from its queue.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PaneEvent] = []
    func add(_ event: PaneEvent) { lock.withLock { events.append(event) } }
    var all: [PaneEvent] { lock.withLock { events } }

    func wait(for count: Int, timeout: TimeInterval = 5) async throws -> [PaneEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while all.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return all
    }
}

/// Connects to the socket as `loam hook` does, writes the bytes, and closes.
func sendToSocket(_ path: String, _ text: String, close: Bool = true) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1  // A write to a dropped connection fails with EPIPE, not a signal.
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8)
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { Darwin.close(fd); throw PaneSocketServer.SocketError.system("connect", errno) }
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, bytes.count) }
    if close { Darwin.close(fd) }
    return fd
}

@Suite struct PaneSocketTests {
    func folder() -> PaneSocketFolder {
        // The temp folder of a test run can be long. /tmp keeps the path under 104 bytes.
        PaneSocketFolder(base: URL(fileURLWithPath: "/tmp/loam-test-\(UUID().uuidString.prefix(8))"))
    }

    @Test func linesSkipWhatIsNotAPaneEvent() {
        let text = """
            {"event":"SessionStart","session_id":"a","cwd":"/x","source":"startup","at":"t","later_field":1}
            not json
            {"event":"LaterEvent","session_id":"a","cwd":"/x","at":"t"}

            {"event":"Stop"}
            {"event":"Stop","session_id":"a","cwd":"/x","at":"t"}
            """
        let events = PaneEvent.lines(in: Data(text.utf8))
        #expect(events.map(\.event) == ["SessionStart", "LaterEvent", "Stop"])
        #expect(events[0].source == "startup")
    }

    @Test func aServerDeliversEachLineOfEachConnection() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let box = EventBox()
        let server = try PaneSocketServer(path: try folder.makePath()) { box.add($0) }
        defer { server.close() }
        _ = try sendToSocket(server.path, #"{"event":"SessionStart","session_id":"a","cwd":"/x","source":"startup","at":"t"}"# + "\n")
        _ = try sendToSocket(server.path, #"{"event":"UserPromptSubmit","session_id":"a","cwd":"/x","at":"t"}"# + "\n" +
                                          #"{"event":"Stop","session_id":"a","cwd":"/x","at":"t"}"#)  // The last line has no newline.
        let events = try await box.wait(for: 3)
        #expect(events.map(\.event) == ["SessionStart", "UserPromptSubmit", "Stop"])
    }

    @Test func theSocketFileIsYoursOnlyAndCloseRemovesIt() throws {
        let folder = folder()
        defer { folder.removeAll() }
        let server = try PaneSocketServer(path: try folder.makePath()) { _ in }
        let info = try FileManager.default.attributesOfItem(atPath: server.path)
        #expect((info[.posixPermissions] as? Int) == 0o600)
        let folderInfo = try FileManager.default.attributesOfItem(atPath: folder.folder.path)
        #expect((folderInfo[.posixPermissions] as? Int) == 0o700)
        server.close()
        server.close()
        #expect(!FileManager.default.fileExists(atPath: server.path))
        #expect(throws: (any Error).self) { _ = try sendToSocket(server.path, "x") }
    }

    @Test func aSlowClientDoesNotHoldUpTheOthers() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let box = EventBox()
        let server = try PaneSocketServer(path: try folder.makePath()) { box.add($0) }
        defer { server.close() }
        let open = try sendToSocket(server.path, #"{"event":"Stop","session_id":"slow","cwd":"/x","at":"t"}"#, close: false)
        _ = try sendToSocket(server.path, #"{"event":"Stop","session_id":"fast","cwd":"/x","at":"t"}"# + "\n")
        let events = try await box.wait(for: 1)
        #expect(events.map(\.sessionID) == ["fast"])
        Darwin.close(open)
        #expect(try await box.wait(for: 2).map(\.sessionID) == ["fast", "slow"])
    }

    @Test func aConnectionWithAHugeLineIsDropped() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let box = EventBox()
        let server = try PaneSocketServer(path: try folder.makePath()) { box.add($0) }
        defer { server.close() }
        let open = try sendToSocket(server.path, String(repeating: "x", count: PaneSocketServer.maxLineBytes + 4096), close: false)
        defer { Darwin.close(open) }
        _ = try sendToSocket(server.path, #"{"event":"Stop","session_id":"ok","cwd":"/x","at":"t"}"# + "\n")
        #expect(try await box.wait(for: 1).map(\.sessionID) == ["ok"])
    }

    @Test func anAcceptErrorDoesNotSpin() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let box = EventBox()
        let accepts = AcceptCounter()
        let failing = AcceptFlag(true)
        var options = PaneSocketServer.Options()
        options.acceptPause = .milliseconds(100)
        options.accept = { listener in
            accepts.add()
            if failing.value { return (-1, EMFILE) }
            let client = Darwin.accept(listener, nil, nil)
            return (client, client < 0 ? errno : 0)
        }
        let server = try PaneSocketServer(path: try folder.makePath(), options: options) { box.add($0) }
        defer { server.close() }
        // The connection waits in the queue while every accept fails.
        _ = try sendToSocket(server.path, #"{"event":"Stop","session_id":"late","cwd":"/x","at":"t"}"# + "\n")
        try await Task.sleep(for: .seconds(1))
        // A spin calls accept millions of times in a second. A pause of 100 ms allows about 10.
        #expect(accepts.value >= 1)
        #expect(accepts.value < 50)
        #expect(box.all.isEmpty)
        // When accept works again, the waiting connection gets through.
        failing.value = false
        #expect(try await box.wait(for: 1).map(\.sessionID) == ["late"])
    }

    @Test func aHungWriterIsClosedAfterTheReadTimeout() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let box = EventBox()
        var options = PaneSocketServer.Options()
        options.readTimeout = .milliseconds(200)
        let server = try PaneSocketServer(path: try folder.makePath(), options: options) { box.add($0) }
        defer { server.close() }
        let open = try sendToSocket(server.path, #"{"event":"Stop","session_id":"hung","cwd":"/x","at":"t"}"#, close: false)
        defer { Darwin.close(open) }
        // The server closes its end: a read on the client end sees the end of the connection.
        var byte: UInt8 = 0
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(open, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #expect(Darwin.read(open, &byte, 1) == 0)
        // The connection ends as if the writer closed it, so the last line counts.
        #expect(try await box.wait(for: 1).map(\.sessionID) == ["hung"])
    }

    @Test func closingAServerFromAnotherServersQueueRunsOnItsOwnQueue() async throws {
        let folder = folder()
        defer { folder.removeAll() }
        let a = try PaneSocketServer(path: try folder.makePath()) { _ in }
        let done = EventBox()
        // B's events run on B's queue. Closing A there must go through A's queue: the close
        // checks that it runs on A's queue and stops the test process if not.
        let b = try PaneSocketServer(path: try folder.makePath()) { event in
            a.close()
            done.add(event)
        }
        defer { b.close() }
        _ = try sendToSocket(b.path, #"{"event":"Stop","session_id":"b","cwd":"/x","at":"t"}"# + "\n")
        #expect(try await done.wait(for: 1).map(\.sessionID) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(throws: (any Error).self) { _ = try sendToSocket(a.path, "x") }
        // B still works.
        _ = try sendToSocket(b.path, #"{"event":"Stop","session_id":"b2","cwd":"/x","at":"t"}"# + "\n")
        #expect(try await done.wait(for: 2).map(\.sessionID) == ["b", "b2"])
    }

    @Test func aPathThatIsTooLongFails() {
        let long = "/tmp/" + String(repeating: "x", count: 120)
        #expect(throws: PaneSocketServer.SocketError.pathTooLong(long)) { _ = try PaneSocketServer(path: long) { _ in } }
    }

    @Test func eachPathIsNewAndShort() throws {
        let folder = PaneSocketFolder()
        defer { folder.removeAll() }
        let a = try folder.makePath(), b = try folder.makePath()
        #expect(a != b)
        #expect(a.utf8.count < 104)
    }
}

final class AcceptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class AcceptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool
    init(_ value: Bool) { state = value }
    var value: Bool {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
}
