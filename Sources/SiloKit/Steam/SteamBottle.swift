import Foundation

/// The shared "Steam bottle": one Wine prefix that hosts a logged-in **Windows Steam client** plus the
/// games that run co-resident with it. This is the post-revert model for Steamworks/DRM games —
/// Steamworks IPC is prefix-scoped, so the game and its Steam client must share a prefix.
///
/// Flow: `provision` (wineboot) → `installSteam` (silent SteamSetup.exe) → `launchSteam` → the user signs
/// in once (Steam caches it) → launch games in the same prefix. All process execution goes through the
/// `ProcessRunning` seam, so the orchestration unit-tests with no Wine/Steam present; the runtime
/// behaviour is validated on a real Mac.
public struct SteamBottle: Sendable {
    private let runner: ProcessRunning
    private let session: URLSession
    private let paths: AppPaths
    private var fileManager: FileManager { .default }

    public init(runner: ProcessRunning, session: URLSession = .shared, paths: AppPaths) {
        self.runner = runner
        self.session = session
        self.paths = paths
    }

    public enum BottleError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(Int32)
        case installerDownloadFailed(Int)
        case steamInstallFailed(Int32)
    }

    /// Steam is installed in the bottle once `steam.exe` exists.
    public var isSteamInstalled: Bool { fileManager.fileExists(atPath: paths.steamBottleExe.path) }

    /// The bottle prefix is booted once it has a `system.reg` + `drive_c`.
    public var isProvisioned: Bool {
        let layout = PrefixLayout(prefix: paths.steamBottle)
        return fileManager.fileExists(atPath: layout.systemReg.path)
            && fileManager.fileExists(atPath: layout.driveC.path)
    }

    // MARK: - Provision + install

    /// Boot the bottle prefix (idempotent).
    public func provision(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isProvisioned { return }
        try fileManager.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        var environment = Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine)
        environment["WINEDLLOVERRIDES"] = Silo.winePrefixInitOverrides
        let result = try await runner.run(
            executable: wine, arguments: ["wineboot", "--init"],
            environment: environment, currentDirectory: nil)
        guard result.succeeded else { throw BottleError.winebootFailed(result.exitCode) }
    }

    /// Provision the bottle and run a silent Windows Steam install into it (idempotent — no-op if Steam
    /// is already present).
    public func installSteam(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isSteamInstalled { return }
        try await provision(wine: wine)
        let installer = try await downloadInstaller()
        let result = try await runner.run(
            executable: wine, arguments: [installer.path, "/S"],
            environment: Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine),
            currentDirectory: paths.steamBottle)
        guard result.succeeded else { throw BottleError.steamInstallFailed(result.exitCode) }
    }

    // MARK: - Launch

    /// Steam flags aimed at getting `steamwebhelper`'s Chromium UI to paint under Wine (without them it's
    /// a black window). `-cef-disable-gpu`/`-cef-disable-gpu-compositing` force software rendering;
    /// `-no-cef-sandbox` avoids the CEF crash-loop; `-cef-disable-chrome-runtime` selects CEF's older
    /// "alloy" runtime, which paints under Wine where the default chrome runtime doesn't. (The fully
    /// proven fix is `--single-process` injected into steamwebhelper via a wrapper — no steam.exe flag
    /// exists for it — which is what the patched-wine build adds.)
    public static let cefRenderArgs = [
        "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox", "-cef-disable-chrome-runtime",
    ]

    /// Launch the bottle's Steam client detached. Defaults to the CEF-render flags so the (one-time)
    /// login window paints; pass `["-silent", …]` to start to tray once a login is cached.
    @discardableResult
    public func launchSteam(wine: URL?, extraArgs: [String] = SteamBottle.cefRenderArgs) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        return try await runner.spawnDetached(
            executable: wine, arguments: [paths.steamBottleExe.path] + extraArgs,
            environment: Silo.wineEnvironment(prefix: paths.steamBottle, wine: wine),
            currentDirectory: paths.steamBottleClientDir, logURL: paths.steamBottleLog)
    }

    /// Launch a game executable **inside the bottle prefix** (co-resident with the running Steam client),
    /// with a caller-built environment (GPTK/D3DMetal etc.). Returns the child PID.
    @discardableResult
    public func launchGame(
        exe: URL, wine: URL, environment: [String: String], logURL: URL
    ) async throws -> Int32 {
        var env = environment
        env["WINEPREFIX"] = paths.steamBottle.path   // force the shared bottle, never an isolated prefix
        return try await runner.spawnDetached(
            executable: wine, arguments: [exe.path],
            environment: env, currentDirectory: exe.deletingLastPathComponent(), logURL: logURL)
    }

    // MARK: - Helpers

    private func downloadInstaller() async throws -> URL {
        let dest = paths.steamBottle.appendingPathComponent("SteamSetup.exe")
        if fileManager.fileExists(atPath: dest.path) { return dest }
        try fileManager.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        let (tempFile, response) = try await session.download(from: Silo.steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BottleError.installerDownloadFailed(http.statusCode)
        }
        try fileManager.moveItem(at: tempFile, to: dest)
        return dest
    }
}
