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
        progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> URL {
        guard let wine else { throw InstallError.wineNotConfigured }
        let fileManager = FileManager.default
        let env = ["WINEPREFIX": bottle.path, "WINEDEBUG": "-all"]

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
        let install = try await runner.run(
            executable: wine, arguments: [setup.path, "/S"], environment: env, currentDirectory: nil)
        guard install.succeeded else { throw InstallError.installerFailed(exitCode: install.exitCode) }

        progress?(.done)
        return bottle
    }
}
