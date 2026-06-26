import Foundation

/// One-click setup of the Master Steam bottle: boot a simple Wine bottle, download the official
/// Steam Windows installer, and run it silently. The user then logs in and downloads games.
///
/// Steam can be finicky under GPTK; the caller passes the wine binary to use (vanilla wine is a good
/// fallback — see `BackendConfig.steamWine`).
public struct SteamBottleInstaller: Sendable {
    private let runner: ProcessRunning
    private let session: URLSession

    public init(runner: ProcessRunning, session: URLSession = .shared) {
        self.runner = runner
        self.session = session
    }

    public enum Stage: Sendable, Equatable { case booting, downloading, installing, done }

    public enum InstallError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(exitCode: Int32)
        case downloadFailed(Int)
        case installerFailed(exitCode: Int32)
    }

    @discardableResult
    public func install(
        bottle: URL,
        wine: URL?,
        installerURL: URL = Silo.steamInstallerURL,
        pollTimeout: Duration = .seconds(180),
        pollInterval: Duration = .seconds(1),
        progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> URL {
        guard let wine else { throw InstallError.wineNotConfigured }
        let fileManager = FileManager.default
        // Disable mono/gecko so first-run wineboot doesn't hang on install dialogs.
        let env = ["WINEPREFIX": bottle.path, "WINEDEBUG": "-all",
                   "WINEDLLOVERRIDES": Silo.winePrefixInitOverrides,
                   "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback]

        progress?(.booting)
        try fileManager.createDirectory(at: bottle, withIntermediateDirectories: true)
        let boot = try await runner.run(
            executable: wine, arguments: ["wineboot", "--init"], environment: env, currentDirectory: nil)
        guard boot.succeeded else { throw InstallError.winebootFailed(exitCode: boot.exitCode) }

        progress?(.downloading)
        let (tempFile, response) = try await session.download(from: installerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.downloadFailed(http.statusCode)
        }
        let setup = bottle.appendingPathComponent("SteamSetup.exe")
        if fileManager.fileExists(atPath: setup.path) { try fileManager.removeItem(at: setup) }
        try fileManager.moveItem(at: tempFile, to: setup)

        progress?(.installing)
        // Steam's silent bootstrapper drops Steam.exe and then auto-launches it. That first launch
        // crash-loops under wine (the Steam CEF issue), so `SteamSetup.exe /S` NEVER returns and the
        // crash handler spawns hundreds of `winedbg` processes. So: spawn the installer detached, wait
        // for Steam.exe to appear, then kill the whole bottle so the crash-loop can't accumulate. The
        // full client downloads on the first real run via "Open Steam" (which passes CEF-safe flags).
        let setupLog = bottle.appendingPathComponent("SteamSetup.log")
        _ = try await runner.spawnDetached(
            executable: wine, arguments: [setup.path, "/S"], environment: env,
            currentDirectory: nil, logURL: setupLog)

        let steamExe = DiscoveryEngine.steamRoot(inBottle: bottle).appendingPathComponent("steam.exe")
        let installed = await waitForFile(steamExe, timeout: pollTimeout, interval: pollInterval)
        await killBottle(wine: wine, bottle: bottle)
        guard installed else { throw InstallError.installerFailed(exitCode: -1) }

        progress?(.done)
        return bottle
    }

    /// Poll for a file to appear, up to `timeout`. Returns whether it exists at the end.
    private func waitForFile(_ url: URL, timeout: Duration, interval: Duration) async -> Bool {
        let fileManager = FileManager.default
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if fileManager.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: interval)
        }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Terminate every wine process in the bottle (`wineserver -k`) — stops the Steam CEF crash-loop.
    private func killBottle(wine: URL, bottle: URL) async {
        let wineserver = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        _ = try? await runner.run(
            executable: wineserver, arguments: ["-k"],
            environment: ["WINEPREFIX": bottle.path], currentDirectory: nil)
    }
}
