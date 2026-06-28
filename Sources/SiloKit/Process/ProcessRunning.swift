import Foundation

/// A cancellable handle to an event observation (process exit / file write). Held by the observer
/// (on the main actor); dropping or cancelling it stops the observation and frees OS resources.
/// Not `Sendable` by design — it never leaves the actor that created it.
public protocol ProcessObservation: AnyObject {
    func cancel()
}

/// The single seam through which Silo executes external binaries (wine, wineboot, codesign, …).
///
/// Production code uses `SystemProcessRunner`; tests inject a fake so provisioning, linking, and
/// launching can be verified with no Wine installed.
public protocol ProcessRunning: Sendable {
    /// Run to completion, capturing output. Used for short commands (e.g. `wineboot --init`).
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?
    ) async throws -> ProcessResult

    /// Spawn detached (does not wait), streaming stdout+stderr to `logURL`. Used to launch the game.
    /// Returns the child PID.
    @discardableResult
    func spawnDetached(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        logURL: URL
    ) async throws -> Int32

    /// Whether a process with this PID is currently alive (for tracking a launched game).
    func isRunning(pid: Int32) -> Bool

    /// Terminate a process by PID (SIGTERM). Used to stop a running game. No-op default.
    func terminate(pid: Int32)

    /// Observe a process's exit **without polling** (kqueue): `onExit` fires once when `pid` dies.
    /// The returned token must be retained to keep observing; cancelling/dropping it stops.
    func observeExit(pid: Int32, onExit: @escaping @Sendable () -> Void) -> any ProcessObservation
}

/// A token that observes nothing — for conformers (and platforms) without event support.
public final class NoopObservation: ProcessObservation {
    public init() {}
    public func cancel() {}
}

extension ProcessRunning {
    public func terminate(pid: Int32) {}
}
