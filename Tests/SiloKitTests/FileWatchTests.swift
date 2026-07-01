import Foundation
import Testing
@testable import SiloKit

@Suite("FileWatch")
struct FileWatchTests {

    @Test("fires onChange when the watched file is written")
    func firesOnWrite() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let file = tmp.url.appendingPathComponent("watched.reg")
        try Data("init".utf8).write(to: file)

        let flag = TestFlag()
        let watch = try #require(FileWatch(url: file) { flag.set() })
        try await Task.sleep(for: .milliseconds(50))   // let the dispatch source arm before we write

        let handle = try FileHandle(forWritingTo: file)   // in-place write (mirrors Wine's registry save)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" appended".utf8))
        try handle.close()

        // Bounded wait for the background event (the handler runs on a global queue).
        for _ in 0..<100 {
            if flag.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(flag.value)
        withExtendedLifetime(watch) {}   // keep the watch alive through the wait
    }

    @Test("init returns nil for a file that doesn't exist")
    func nilForMissingFile() {
        let watch = FileWatch(url: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x")) {}
        #expect(watch == nil)
    }

    @MainActor
    @Test("LogTailer creates a missing log file OFF the main actor, arms, and publishes writes")
    func logTailerCreatesAndTails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let log = tmp.url.appendingPathComponent("not-yet.log")
        let tailer = LogTailer()
        tailer.start(url: log)

        // Bounded wait for the detached create + main-actor watch arming.
        for _ in 0..<200 where !tailer.isWatching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tailer.isWatching)
        #expect(FileManager.default.fileExists(atPath: log.path))

        // Append in place (an atomic replace would swap the watched vnode out).
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("wine: launched".utf8))
        try handle.close()

        for _ in 0..<200 where !tailer.contents.contains("wine: launched") {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tailer.contents.contains("wine: launched"))

        // stop() invalidates any in-flight start: a stale arm must not resurrect the watch.
        tailer.stop()
        #expect(!tailer.isWatching)
    }
}

/// Lock-guarded boolean for bridging a background `@Sendable` callback back into an async test.
/// `@unchecked Sendable` is safe: the single `Bool` is guarded by the lock.
final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
