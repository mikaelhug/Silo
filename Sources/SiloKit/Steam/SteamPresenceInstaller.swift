import Foundation

/// Writes the small per-game `steam_appid.txt` so a game's Steamworks can resolve its App ID at startup
/// (the co-resident Steam client in the bottle handles the rest). Never downloads, bundles, or modifies a
/// game binary.
public struct SteamPresenceInstaller: Sendable {
    public init() {}

    /// Apply the strategy for a game (`gameExe` locates the install dir). Returns the file written, if any.
    @discardableResult
    public func apply(strategy: SteamPresenceStrategy, appID: Int, gameExe: URL) throws -> URL? {
        switch strategy {
        case .none:
            return nil
        case .steamAppIDFile:
            let file = gameExe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
            try "\(appID)".write(to: file, atomically: true, encoding: .utf8)
            return file
        }
    }
}
