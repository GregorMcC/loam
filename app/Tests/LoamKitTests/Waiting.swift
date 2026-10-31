import Foundation
import Testing

// The waits of the tests. A wait ends when its condition holds, never at a time on the wall clock: a busy machine
// (a full parallel run beside other builds) makes the async work slow, and a fixed limit then fails a test that is
// right. A suite that waits has the time limit `.waitLimit`, which ends a wait for a condition that never comes. The
// wait then fails the test where it waits.

extension Trait where Self == TimeLimitTrait {
    /// The time limit of a test that waits. It only ends a wait that never ends, so it is far longer than a test takes.
    /// A busy machine can hold the launch of each process for more than a minute: macOS checks the fake `loam` before
    /// it runs, and that check waits when other builds and test runs use the machine.
    static var waitLimit: Self { .timeLimit(.minutes(5)) }
}

/// Whether the tests run in a sandbox, as in the Bash of a Loam run or in its gate. A sandbox cannot start another
/// one, so `sandbox-exec` fails there.
let inSandbox: Bool = {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    probe.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
    probe.standardError = FileHandle.nullDevice
    guard (try? probe.run()) != nil else { return false }
    probe.waitUntilExit()
    return probe.terminationStatus != 0
}()

extension Trait where Self == ConditionTrait {
    /// A test that needs a service that the sandbox of a Loam run denies, such as FSEvents or the process list, skips
    /// in a sandbox. CI and a test run outside a sandbox still run it.
    static var outsideASandbox: Self { .disabled(if: inSandbox, "the sandbox denies the services that this test needs") }
}

/// Returns when `condition` holds, or when the test is cancelled at its time limit. It looks again every `interval`,
/// so it suits a condition that another process changes, such as a fake `loam` that logs its calls. It runs on the
/// actor of its caller, so `condition` can read the state of that actor. It records nothing: the caller checks after it.
nonisolated(nonsending) func poll(every interval: Duration = .milliseconds(5), until condition: () -> Bool) async {
    while !condition(), !Task.isCancelled { try? await Task.sleep(for: interval) }
}

/// `poll`, then an expectation that says what did not happen.
nonisolated(nonsending) func waitUntil(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                                       _ condition: () -> Bool) async {
    await poll(until: condition)
    #expect(condition(), "\(what) did not happen", sourceLocation: sourceLocation)
}

/// The waits for the state of an in-process fake. The fake calls `changed()` after each change, and each wait whose
/// condition now holds ends at once. Nothing polls and nothing reads a clock.
@MainActor
final class Changes {
    private var waits: [(id: Int, ready: @MainActor () -> Bool, wake: CheckedContinuation<Void, Never>)] = []
    private var next = 0

    /// Returns when `ready` holds, or when the test is cancelled at its time limit.
    func wait(until ready: @escaping @MainActor () -> Bool) async {
        guard !ready() else { return }
        let id = next
        next += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (wake: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { wake.resume(); return }
                waits.append((id, ready, wake))
            }
        } onCancel: {
            Task { @MainActor in self.end(id) }
        }
    }

    /// Ends each wait whose condition holds now.
    func changed() {
        var waiting: [(id: Int, ready: @MainActor () -> Bool, wake: CheckedContinuation<Void, Never>)] = []
        var done: [CheckedContinuation<Void, Never>] = []
        for wait in waits {
            if wait.ready() { done.append(wait.wake) } else { waiting.append(wait) }
        }
        waits = waiting
        for wake in done { wake.resume() }
    }

    private func end(_ id: Int) {
        guard let index = waits.firstIndex(where: { $0.id == id }) else { return }
        waits.remove(at: index).wake.resume()
    }
}
