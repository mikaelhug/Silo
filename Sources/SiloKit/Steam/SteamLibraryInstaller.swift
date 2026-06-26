import Foundation

/// Queues downloads for a set of apps by handing `steam://install/<appid>` URLs to the running Steam
/// client inside the Master bottle. There is no single "install whole library" command, so this
/// fires one URL per app; Steam (which must be running + logged in) queues each download.
public struct SteamLibraryInstaller: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning) { self.runner = runner }

    public enum InstallError: Error, Sendable, Equatable {
        case wineNotConfigured
        case steamNotFound(URL)
        case noApps
    }

    /// Queue installs for `appIDs`. Returns the number queued.
    @discardableResult
    public func queueInstalls(appIDs: [Int], bottle: URL, wine: URL?) async throws -> Int {
        guard let wine else { throw InstallError.wineNotConfigured }
        guard !appIDs.isEmpty else { throw InstallError.noApps }
        let steamExe = DiscoveryEngine.steamRoot(inBottle: bottle)
            .appendingPathComponent("steam.exe")
        guard FileManager.default.fileExists(atPath: steamExe.path) else {
            throw InstallError.steamNotFound(steamExe)
        }

        let env = ["WINEPREFIX": bottle.path, "WINEDEBUG": "-all"]
        for appID in appIDs {
            _ = try await runner.run(
                executable: wine,
                arguments: [steamExe.path, "steam://install/\(appID)"],
                environment: env, currentDirectory: nil)
        }
        return appIDs.count
    }
}
