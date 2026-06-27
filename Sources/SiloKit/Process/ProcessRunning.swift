import Foundation

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

    /// Best-effort count of running processes whose full command line contains `pattern`.
    /// Used by `CrashLoopGuard` to detect a `winedbg` storm. Defaults to 0 for conformers that don't
    /// implement it.
    func processCount(matching pattern: String) async -> Int
}

extension ProcessRunning {
    public func processCount(matching pattern: String) async -> Int { 0 }
}
