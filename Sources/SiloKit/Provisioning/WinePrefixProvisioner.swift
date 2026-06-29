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
        var environment = Silo.wineEnvironment(prefix: prefix, wine: wine)
        environment["WINEDLLOVERRIDES"] = Silo.winePrefixInitOverrides
        let result = try await runner.run(
            executable: wine, arguments: ["wineboot", "--init"],
            environment: environment, currentDirectory: nil)
        guard result.succeeded else { throw ProvisionError.winebootFailed(result.exitCode) }
    }
}
