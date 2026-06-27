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
    /// Returned by `spawnDetached`.
    var spawnPID: Int32 = 4242
    /// Invoked (outside the lock) for every call, before returning — use to mutate a fake FS.
    var onRun: (@Sendable (Invocation) -> Void)?

    private var _alivePIDs: Set<Int32> = []
    private var _processCount = 0
    private var _matching: Set<String> = []
    private var _exitHandlers: [Int32: [(id: Int, run: @Sendable () -> Void)]] = [:]
    private var _nextObservationID = 0

    var invocations: [Invocation] { lock.withLock { _invocations } }
    var lastInvocation: Invocation? { lock.withLock { _invocations.last } }

    /// Value returned by `processCount` (set high in tests to simulate a winedbg storm).
    var processCountValue: Int {
        get { lock.withLock { _processCount } }
        set { lock.withLock { _processCount = newValue } }
    }
    /// Exact patterns considered "running" (e.g. "app_update 70") — returns 1 for those, else the default.
    var matchingProcesses: Set<String> {
        get { lock.withLock { _matching } }
        set { lock.withLock { _matching = newValue } }
    }
    func processCount(matching pattern: String) async -> Int {
        lock.withLock { _matching.contains(pattern) ? 1 : _processCount }
    }
    func firstPID(matching pattern: String) async -> Int32? {
        lock.withLock { _matching.contains(pattern) ? spawnPID : nil }
    }

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
    func isRunning(pid: Int32) -> Bool { lock.withLock { _alivePIDs.contains(pid) } }

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
    func observeWrites(at url: URL, onWrite: @escaping @Sendable () -> Void) -> any ProcessObservation {
        FakeObservation {}   // tests drive progress via the manifest, not live log writes
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
        let (hook, result): (((Invocation) -> Void)?, ProcessResult) = lock.withLock {
            _invocations.append(invocation)
            let result = _results.isEmpty ? defaultResult : _results.removeFirst()
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
            _alivePIDs.insert(spawnPID)   // a spawned game is "running" until a test marks it exited
            return (onRun, spawnPID)
        }
        hook?(invocation)
        return pid
    }
}

/// Cancellable token returned by the fake's observers; runs `onCancel` to detach the handler.
final class FakeObservation: ProcessObservation {
    private let onCancel: @Sendable () -> Void
    init(_ onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}
