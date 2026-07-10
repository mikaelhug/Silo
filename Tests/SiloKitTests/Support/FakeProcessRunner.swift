import Foundation
@testable import SiloKit

/// Test double for `ProcessRunning`. Records every invocation, returns scripted results, and can
/// run a side-effect hook (e.g. to simulate `wineboot` creating `system.reg`).
///
/// `@unchecked Sendable` is safe here: all mutable state is guarded by `lock`.
final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {

    struct Invocation: Equatable, Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: URL?
        let detached: Bool
        let logURL: URL?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    private var _results: [ProcessResult] = []

    /// Returned by `run` when no scripted result is queued.
    var defaultResult = ProcessResult(exitCode: 0)
    /// First PID handed out by `spawnDetached`; each subsequent spawn gets the next integer, so
    /// distinct detached processes (e.g. the bottle Steam vs. a game) don't collide on one PID.
    /// Setting this resets the counter (back-compat for tests that assert the first spawn == 4242).
    var spawnPID: Int32 = 4242 {
        didSet { lock.withLock { _nextSpawnPID = spawnPID } }
    }
    /// Invoked (outside the lock) for every call, before returning — use to mutate a fake FS.
    var onRun: (@Sendable (Invocation) -> Void)?
    /// Optional async barrier awaited inside `spawnDetached` AFTER the invocation is recorded but BEFORE the
    /// PID is returned — lets a test hold a spawn "in flight" to exercise mid-spawn coalescing.
    var onSpawnAwait: (@Sendable () async -> Void)?

    private var _nextSpawnPID: Int32 = 4242
    private var _alivePIDs: Set<Int32> = []
    private var _terminatedPIDs: [Int32] = []

    var invocations: [Invocation] { lock.withLock { _invocations } }
    var lastInvocation: Invocation? { lock.withLock { _invocations.last } }
    /// PIDs sent SIGTERM via `terminate(pid:)`.
    var terminatedPIDs: [Int32] { lock.withLock { _terminatedPIDs } }

    /// Simulate a process exiting (or coming alive) — flips what `isRunning(pid:)` reports.
    func setAlive(_ pid: Int32, _ alive: Bool) {
        lock.withLock { if alive { _alivePIDs.insert(pid) } else { _alivePIDs.remove(pid) } }
    }

    func isRunning(pid: Int32) -> Bool { lock.withLock { _alivePIDs.contains(pid) } }

    /// Record a SIGTERM and stop reporting the PID as alive (mirrors the real runner). Used only by the
    /// first-run warm-up.
    func terminate(pid: Int32) {
        lock.withLock {
            _terminatedPIDs.append(pid)
            _alivePIDs.remove(pid)
        }
    }

    /// Queue a result to be returned by the next `run` call (FIFO).
    func queueResult(_ result: ProcessResult) {
        lock.withLock { _results.append(result) }
    }

    func run(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?
    ) async throws -> ProcessResult {
        let invocation = Invocation(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, detached: false, logURL: nil
        )
        // Simulate Steam teardown: `steam.exe -shutdown` and `taskkill /F` kill the running (spawned) Steam
        // processes, mirroring the real runner. Without this the warm-up's post-download shutdown/force-quit
        // would wait out its full failsafe against fake PIDs that never die (a 25s+ per-test hang).
        let killsSpawned = arguments.contains("-shutdown") || arguments.first == "taskkill"
        let (hook, result): (((Invocation) -> Void)?, ProcessResult) =
            lock.withLock {
                _invocations.append(invocation)
                let result = _results.isEmpty ? defaultResult : _results.removeFirst()
                if killsSpawned { _alivePIDs.removeAll() }
                return (onRun, result)
            }
        hook?(invocation)
        return result
    }

    @discardableResult
    func spawnDetached(
        executable: URL, arguments: [String],
        environment: [String: String], currentDirectory: URL?, logURL: URL
    ) async throws -> Int32 {
        let invocation = Invocation(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, detached: true, logURL: logURL
        )
        let (hook, pid): (((Invocation) -> Void)?, Int32) = lock.withLock {
            _invocations.append(invocation)
            let pid = _nextSpawnPID; _nextSpawnPID += 1
            _alivePIDs.insert(pid)   // a spawned game is "running" until a test marks it exited
            return (onRun, pid)
        }
        hook?(invocation)
        if let barrier = onSpawnAwait { await barrier() }   // hold the spawn in flight if a test asked
        return pid
    }
}
