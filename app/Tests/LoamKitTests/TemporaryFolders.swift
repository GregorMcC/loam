import Foundation
import Testing

// The temp folders of the tests (TAS-214). A test that needs a folder or a file on disk makes it with
// `temporaryFolder(_:)`, and the test or its suite has the trait `.temporaryFolders`. The trait removes each folder
// that the test made when the test ends. A value that the tests share for the whole run, such as a `static let`, uses
// `runFolder` instead. When the process exits, it removes every folder of the run again: a write that ends after its
// test, such as a delayed write of `state.json`, can make a folder again after the test removed it. So a test run
// leaves nothing in the temp folder, and scripts/check.sh fails when a run of the app tests leaves a folder there.
//
// LoamDriverTests links this file from LoamKitTests, so both test targets use the same helper.

/// A list of temp items to remove.
final class TemporaryItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []

    func add(_ item: URL) { lock.withLock { items.append(item) } }

    func removeAll() {
        let all = lock.withLock { defer { items = [] }; return items }
        for item in all { try? FileManager.default.removeItem(at: item) }
    }
}

/// The items that one test made. The trait `.temporaryFolders` removes them when the test ends.
enum TemporaryFolders {
    /// The items of the test that runs in this task, or nil outside the trait.
    @TaskLocal static var current: TemporaryItems?
}

/// Every temp item of the run. The process removes them when it exits.
private let itemsOfTheRun = TemporaryItems()

/// Registers the removal at exit, once. An exit handler cannot capture a value, so it reads a global.
private let removeAtExit: Void = { atexit { itemsOfTheRun.removeAll() } }()

private func removeWhenTheProcessExits(_ item: URL) {
    _ = removeAtExit
    itemsOfTheRun.add(item)
}

/// The trait that gives each test its `TemporaryItems` and removes them when the test ends. On a suite, it applies to
/// each test of the suite and of its nested suites, and to each case of a test with arguments.
struct TemporaryFoldersTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let items = TemporaryItems()
        defer { items.removeAll() }
        try await TemporaryFolders.$current.withValue(items) { try await function() }
    }
}

extension Trait where Self == TemporaryFoldersTrait {
    /// Removes the folders that `temporaryFolder(_:)` makes when the test ends.
    static var temporaryFolders: Self { Self() }
}

/// The tag of the test run in the names of its temp folders: `LOAM_TEST_RUN` and a hyphen, or nothing. scripts/check.sh
/// sets it, so that its check of the shared temp folder sees the folders of this run only, not those of another process.
let runTag = ProcessInfo.processInfo.environment["LOAM_TEST_RUN"].map { "\($0)-" } ?? ""

/// Makes a new empty folder `loam-test-<run tag><name>-<UUID>` in the temp folder. The folder and all that the test puts in it
/// go when the test ends. The test or its suite needs the trait `.temporaryFolders`: without it, the test fails.
func temporaryFolder(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loam-test-\(runTag)\(name)-\(UUID().uuidString)")
    removeWhenTheTestEnds(folder, sourceLocation: sourceLocation)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
        Issue.record(error, "cannot make \(folder.path)", sourceLocation: sourceLocation)
    }
    return folder
}

/// Removes `item` and all that is in it when the test ends, for a temp item that must be somewhere other than in a
/// `temporaryFolder(_:)`, such as a short path for a socket. The test or its suite needs the trait `.temporaryFolders`.
func removeWhenTheTestEnds(_ item: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    removeWhenTheProcessExits(item)
    guard let items = TemporaryFolders.current else {
        Issue.record(
            "A temp folder needs the trait .temporaryFolders on the test or its suite, so that it goes when the test ends.",
            sourceLocation: sourceLocation)
        return
    }
    items.add(item)
}

/// A folder `loam-test-<run tag>run-<UUID>` in the temp folder for the values that the tests share for the whole run, such as a
/// `static let`. A test must not put its own files here: it uses `temporaryFolder(_:)`. The process removes the folder
/// when it exits.
let runFolder: URL = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loam-test-\(runTag)run-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    removeWhenTheProcessExits(folder)
    return folder
}()
