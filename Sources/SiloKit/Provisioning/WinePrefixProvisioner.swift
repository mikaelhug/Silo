import Foundation

/// Boots a fresh Wine prefix (`wineboot --init`). Shared by the Steam bottle and the per-game bottles
/// that isolated manual (non-Steam) games run in. All process execution goes through `ProcessRunning`, so
/// this orchestration unit-tests with no Wine installed.
public struct WinePrefixProvisioner: Sendable {
    private let runner: ProcessRunning
    private var fileManager: FileManager { .default }

    public init(runner: ProcessRunning) { self.runner = runner }

    public enum ProvisionError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(Int32)
    }

    /// A prefix is booted once it has a `system.reg` + `drive_c`.
    public func isProvisioned(_ prefix: URL) -> Bool {
        let layout = PrefixLayout(prefix: prefix)
        return fileManager.fileExists(atPath: layout.systemReg.path)
            && fileManager.fileExists(atPath: layout.driveC.path)
    }

    /// Boot `prefix` (idempotent — a no-op once it carries `system.reg` + `drive_c`).
    public func provision(prefix: URL, wine: URL?) async throws {
        guard let wine else { throw ProvisionError.wineNotConfigured }
        if isProvisioned(prefix) { return }
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)
        // msync env: wine starts a SEPARATE wineserver per (prefix, sync-mode), and everything that later
        // runs in this prefix is msync (Silo.enforceMsync) — booting with the same mode means the prefix
        // only ever sees ONE wineserver flavor, so a boot server can't linger alongside a launch server
        // and race its registry writes.
        var environment = Silo.msyncWineEnvironment(prefix: prefix, wine: wine)
        environment["WINEDLLOVERRIDES"] = Silo.winePrefixInitOverrides
        let result = try await runner.run(
            executable: wine, arguments: ["wineboot", "--init"],
            environment: environment, currentDirectory: nil)
        guard result.succeeded else { throw ProvisionError.winebootFailed(result.exitCode) }

        // Settle the boot wineserver before returning. `wineboot` leaves a transient server in its
        // shutdown window; a launch fired immediately after (e.g. the installer right after the Add sheet
        // provisions the bottle) races it — the process spawns but can't attach, so it dies with no window,
        // and only a second launch (boot server now gone) works. Killing it leaves a clean prefix so the
        // very first launch attaches cleanly. Best-effort: no server to kill is success. Only runs on the
        // initial boot of a fresh prefix (guarded by `isProvisioned` above).
        let wineserver = WineRuntimeLayout(wineBinary: wine).wineserver
        _ = try? await runner.run(
            executable: wineserver, arguments: ["-k"],
            environment: Silo.msyncWineEnvironment(prefix: prefix, wine: wine), currentDirectory: nil)
    }
}
