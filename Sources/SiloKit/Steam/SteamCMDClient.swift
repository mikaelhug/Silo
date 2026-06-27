import Foundation

/// Installs and drives native macOS **SteamCMD** (the post-pivot downloader). Short queries
/// (app_info / licenses) run to completion and return captured output; a game download is spawned
/// detached and its progress tailed from the log, like a game launch.
///
/// `struct` + injected deps (matches `SteamBottleInstaller`/`Updater`): all I/O goes through the
/// `ProcessRunning` seam and `URLSession`, so it tests with no SteamCMD present.
public struct SteamCMDClient: Sendable {
    private let runner: ProcessRunning
    private let session: URLSession
    private let paths: AppPaths

    public init(runner: ProcessRunning, session: URLSession = .shared, paths: AppPaths) {
        self.runner = runner
        self.session = session
        self.paths = paths
    }

    public enum SteamCMDError: Error, Sendable, Equatable {
        case installDownloadFailed(Int)
        case extractionFailed(exitCode: Int32)
    }

    /// Ensure native SteamCMD is installed; returns its bootstrap script. Downloads + extracts once.
    @discardableResult
    public func ensureInstalled() async throws -> URL {
        let fileManager = FileManager.default
        let script = paths.steamCMDScript
        if fileManager.fileExists(atPath: script.path) { return script }

        try fileManager.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        let (tempFile, response) = try await session.download(from: SteamCMD.macInstallerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SteamCMDError.installDownloadFailed(http.statusCode)
        }
        let tarball = paths.steamCMDDir.appendingPathComponent("steamcmd_osx.tar.gz")
        if fileManager.fileExists(atPath: tarball.path) { try fileManager.removeItem(at: tarball) }
        try fileManager.moveItem(at: tempFile, to: tarball)

        let extract = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["xzf", tarball.path, "-C", paths.steamCMDDir.path],
            environment: [:], currentDirectory: nil)
        guard extract.succeeded else { throw SteamCMDError.extractionFailed(exitCode: extract.exitCode) }
        try? fileManager.removeItem(at: tarball)
        return script
    }

    /// Download a game's **Windows** files into its bucket install dir. Spawned detached; tail `logURL`
    /// for progress and watch the install dir for the depot to land. Returns the child PID.
    @discardableResult
    public func download(appID: Int, username: String, logURL: URL) async throws -> Int32 {
        let installDir = paths.gameInstallDir(forAppID: appID)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let script = try await ensureInstalled()
        return try await runner.spawnDetached(
            executable: script,
            arguments: SteamCMD.downloadArguments(appID: appID, username: username, installDir: installDir),
            environment: [:], currentDirectory: paths.steamCMDDir, logURL: logURL)
    }

    /// Run a short SteamCMD query to completion and return its stdout (for app_info / licenses parsing).
    public func capture(_ arguments: [String]) async throws -> String {
        let script = try await ensureInstalled()
        let result = try await runner.run(
            executable: script, arguments: arguments, environment: [:],
            currentDirectory: paths.steamCMDDir)
        return result.stdoutString
    }

    /// The logged-in account's owned **games that can run on Windows** (the Silo library), sorted by
    /// name. Three batched SteamCMD sessions: licenses → packages → app metadata. (Mac-capable games are
    /// included; the UI filters them out if the user wants strictly Windows-only.)
    public func ownedGames(username: String) async throws -> [SteamAppInfo] {
        let packageIDs = SteamCMD.parseLicensePackageIDs(
            try await capture(SteamCMD.licensesArguments(username: username)))
        guard !packageIDs.isEmpty else { return [] }

        let packageOutput = try await capture(
            SteamCMD.packageInfoArguments(username: username, packageIDs: packageIDs))
        var appIDs = Set<Int>()
        for pkg in packageIDs { appIDs.formUnion(SteamCMD.parsePackageAppIDs(packageOutput, packageID: pkg)) }
        guard !appIDs.isEmpty else { return [] }

        let infoOutput = try await capture(SteamCMD.appInfoArguments(appIDs: Array(appIDs)))
        return SteamAppInfo.parseAll(appInfoOutput: infoOutput, appIDs: Array(appIDs))
            .filter(\.windowsPlayable)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
