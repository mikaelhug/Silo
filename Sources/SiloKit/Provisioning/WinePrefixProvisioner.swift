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

    /// Written only after `wineboot --init` RETURNS SUCCESSFULLY — see `isProvisioned`.
    static func bootMarker(_ prefix: URL) -> URL {
        prefix.appendingPathComponent(".silo-installed/wineboot", isDirectory: false)
    }

    /// A prefix is booted once `wineboot` actually finished. **Not** merely `system.reg` + `drive_c`:
    /// wineboot creates that skeleton early, long before it finishes populating system32, the fakedlls and
    /// the registry — so quitting Silo (or losing power) inside that window used to make `provision` a
    /// permanent no-op, and every later Set up silently continued on a half-booted prefix whose component
    /// installs then misbehaved in confusing ways, with no way to repair it short of deleting the folder.
    /// The skeleton check is kept as a fallback so prefixes booted by earlier versions aren't re-booted.
    public func isProvisioned(_ prefix: URL) -> Bool {
        if fileManager.fileExists(atPath: Self.bootMarker(prefix).path) { return true }
        let layout = PrefixLayout(prefix: prefix)
        // Legacy prefixes (booted before the marker existed) are recognised by a POPULATED system32 —
        // present only once wineboot got past the skeleton stage.
        return fileManager.fileExists(atPath: layout.systemReg.path)
            && fileManager.fileExists(atPath: layout.driveC.path)
            && ((try? fileManager.contentsOfDirectory(
                    atPath: layout.driveC.appendingPathComponent("windows/system32").path))?.count ?? 0) > 50
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
        // Record completion so an interrupted boot is retried rather than mistaken for a booted prefix.
        try? fileManager.createDirectory(
            at: Self.bootMarker(prefix).deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: Self.bootMarker(prefix).path, contents: Data())

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
