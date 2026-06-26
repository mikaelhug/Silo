import Foundation

/// Seeds and tracks per-game isolated Wine prefixes under the Prefixes dir.
///
/// `provision` is idempotent: it returns immediately if the prefix already looks booted (a
/// `system.reg` and `drive_c` exist), otherwise it runs `wineboot --init` with `WINEPREFIX` pointed
/// at the isolated prefix.
public actor PrefixProvisioner {
    private let runner: ProcessRunning
    private let paths: AppPaths
    private let fileManager: FileManager

    public init(runner: ProcessRunning, paths: AppPaths, fileManager: FileManager = .default) {
        self.runner = runner
        self.paths = paths
        self.fileManager = fileManager
    }

    public enum ProvisionStage: Sendable, Equatable {
        case creatingDirectory, booting, done
    }

    public enum ProvisionError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(exitCode: Int32)
    }

    public nonisolated func prefixURL(forAppID appID: Int) -> URL {
        paths.prefix(forAppID: appID)
    }

    /// Delete a game's prefix (re-seeded on next launch).
    public func remove(appID: Int) throws {
        let prefix = paths.prefix(forAppID: appID)
        if fileManager.fileExists(atPath: prefix.path) { try fileManager.removeItem(at: prefix) }
    }

    public func isProvisioned(appID: Int) -> Bool {
        let layout = PrefixLayout(prefix: paths.prefix(forAppID: appID))
        return fileManager.fileExists(atPath: layout.systemReg.path)
            && fileManager.fileExists(atPath: layout.driveC.path)
    }

    @discardableResult
    public func provision(
        appID: Int,
        wineBinary: URL?,
        progress: (@Sendable (ProvisionStage) -> Void)? = nil
    ) async throws -> URL {
        let prefix = paths.prefix(forAppID: appID)
        if isProvisioned(appID: appID) {
            progress?(.done)
            return prefix
        }
        guard let wineBinary else { throw ProvisionError.wineNotConfigured }

        progress?(.creatingDirectory)
        try fileManager.createDirectory(at: prefix, withIntermediateDirectories: true)

        progress?(.booting)
        let result = try await runner.run(
            executable: wineBinary,
            arguments: ["wineboot", "--init"],
            // Disable mono/gecko so first-run wineboot doesn't hang on install dialogs.
            environment: ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all",
                          "WINEDLLOVERRIDES": Silo.winePrefixInitOverrides,
                          "DYLD_FALLBACK_LIBRARY_PATH": wineBinary.siloDyldFallback],
            currentDirectory: nil
        )
        guard result.succeeded else {
            throw ProvisionError.winebootFailed(exitCode: result.exitCode)
        }

        progress?(.done)
        return prefix
    }
}
