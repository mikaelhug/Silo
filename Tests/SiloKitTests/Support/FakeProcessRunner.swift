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

    var invocations: [Invocation] { lock.withLock { _invocations } }
    var lastInvocation: Invocation? { lock.withLock { _invocations.last } }

    /// Simulate a process exiting (or coming alive) for `isRunning` checks.
    func setAlive(_ pid: Int32, _ alive: Bool) {
        lock.withLock { if alive { _alivePIDs.insert(pid) } else { _alivePIDs.remove(pid) } }
    }
    func isRunning(pid: Int32) -> Bool { lock.withLock { _alivePIDs.contains(pid) } }

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
