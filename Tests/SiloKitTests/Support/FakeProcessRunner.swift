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
    /// PID is returned — lets a test hold a spawn "in flight" to exercise mid-spawn races (e.g. a `stop()`
    /// cancelling a Steam client bring-up before it adopts its PID).
    var onSpawnAwait: (@Sendable () async -> Void)?

    private var _nextSpawnPID: Int32 = 4242
    private var _alivePIDs: Set<Int32> = []
    /// Synthetic start times backing `startTime(pid:)` (for `ProcessLedger` identity). Auto-assigned per
    /// PID on first query of a live PID; a test overrides one via `setStartTime` to simulate PID reuse.
    private var _startTimes: [Int32: Date] = [:]
    private var _terminatedPIDs: [Int32] = []
    private var _exitHandlers: [Int32: [(id: Int, run: @Sendable () -> Void)]] = [:]
    private var _nextObservationID = 0

    var invocations: [Invocation] { lock.withLock { _invocations } }
    var lastInvocation: Invocation? { lock.withLock { _invocations.last } }
    /// PIDs sent SIGTERM via `terminate(pid:)`.
    var terminatedPIDs: [Int32] { lock.withLock { _terminatedPIDs } }

    /// Simulate a process exiting (or coming alive). When marked dead, fires any `observeExit` handlers.
    func setAlive(_ pid: Int32, _ alive: Bool) {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            if alive { _alivePIDs.insert(pid); return [] }
            _alivePIDs.remove(pid)
            let fired = _exitHandlers[pid]?.map(\.run) ?? []
            _exitHandlers[pid] = nil
            return fired
        }
        handlers.forEach { $0() }
    }
    /// Records the invocation (detached) so tests can assert a fire-and-forget teardown fired. Like the real
    /// runner it does NOT wait; a `taskkill` here also clears the spawned "alive" PIDs so a session's Steam
    /// reads as gone afterward, mirroring `run`'s taskkill handling.
    func spawnDetachedForget(
        executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, logURL: URL) {
        let invocation = Invocation(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, detached: true, logURL: logURL)
        let (hook, killed): (((Invocation) -> Void)?, [@Sendable () -> Void]) = lock.withLock {
            _invocations.append(invocation)
            var fired: [@Sendable () -> Void] = []
            if arguments.first == "taskkill" {
                for pid in _alivePIDs { fired += _exitHandlers[pid]?.map(\.run) ?? [] }
                _alivePIDs.removeAll(); _exitHandlers.removeAll()
            }
            return (onRun, fired)
        }
        hook?(invocation)
        killed.forEach { $0() }
    }

    func isRunning(pid: Int32) -> Bool { lock.withLock { _alivePIDs.contains(pid) } }

    /// Mirrors the real runner: a start time only for a LIVE pid, deterministic per pid, stable across
    /// calls. `setStartTime` overrides it to simulate a reused pid (same pid, different start time).
    func startTime(pid: Int32) -> Date? {
        lock.withLock {
            guard _alivePIDs.contains(pid) else { return nil }
            if let existing = _startTimes[pid] { return existing }
            let assigned = Date(timeIntervalSince1970: 1_700_000_000 + Double(pid))
            _startTimes[pid] = assigned
            return assigned
        }
    }

    /// Override a PID's start time (simulate PID reuse for `ProcessLedger` tests).
    func setStartTime(_ pid: Int32, _ date: Date) { lock.withLock { _startTimes[pid] = date } }

    /// When true, `terminate` records the SIGTERM but keeps the PID ALIVE — models a process that ignores
    /// or is slow to act on SIGTERM (the real-world case the crash-orphan ledger must survive).
    var terminateKeepsPIDAlive = false

    /// Record a SIGTERM and (unless `terminateKeepsPIDAlive`) stop reporting the PID as alive (mirrors the
    /// real runner; does NOT fire `observeExit` handlers, matching SIGTERM-vs-kqueue-exit semantics).
    func terminate(pid: Int32) {
        lock.withLock {
            _terminatedPIDs.append(pid)
            if !terminateKeepsPIDAlive { _alivePIDs.remove(pid) }
        }
    }

    func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation {
        let id: Int = lock.withLock {
            let id = _nextObservationID; _nextObservationID += 1
            _exitHandlers[pid, default: []].append((id, onExit))
            return id
        }
        return FakeObservation { [weak self] in
            self?.lock.withLock { self?._exitHandlers[pid]?.removeAll { $0.id == id } }
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
        let (hook, result, killed): (((Invocation) -> Void)?, ProcessResult, [@Sendable () -> Void]) =
            lock.withLock {
                _invocations.append(invocation)
                let result = _results.isEmpty ? defaultResult : _results.removeFirst()
                var fired: [@Sendable () -> Void] = []
                if killsSpawned {
                    for pid in _alivePIDs { fired += _exitHandlers[pid]?.map(\.run) ?? [] }
                    _alivePIDs.removeAll(); _exitHandlers.removeAll()
                }
                return (onRun, result, fired)
            }
        hook?(invocation)
        killed.forEach { $0() }
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

/// Cancellable token returned by the fake's observers; runs `onCancel` to detach the handler.
final class FakeObservation: ProcessObservation {
    private let onCancel: @Sendable () -> Void
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}
