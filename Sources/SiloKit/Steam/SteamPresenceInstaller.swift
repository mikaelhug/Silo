import Foundation

/// Applies a `SteamPresenceStrategy` for a game and produces a reversible `Receipt`.
///
/// Safety: never downloads, bundles, or modifies any game binary — it only writes `steam_appid.txt`
/// (and, for the not-yet-implemented in-prefix client, symlinks a Steam install).
public struct SteamPresenceInstaller: Sendable {
    public init() {}
    private var fileManager: FileManager { .default }

    public enum PresenceError: Error, Sendable, Equatable {
        case steamClientUnavailable
        case prefixRequired
    }

    /// Records what was created so it can be undone.
    public struct Receipt: Codable, Sendable, Equatable {
        public var createdFiles: [URL] = []
    }

    /// Apply the strategy. `gameExe` locates the install dir; `prefix`/`steamClientRoot` are only needed
    /// for `.sharedSteamClient`.
    @discardableResult
    public func apply(
        strategy: SteamPresenceStrategy,
        appID: Int,
        gameExe: URL,
        steamClientRoot: URL? = nil,
        prefix: URL? = nil
    ) throws -> Receipt {
        let dir = gameExe.deletingLastPathComponent()

        switch strategy {
        case .none:
            return Receipt()

        case .steamAppIDFile:
            return Receipt(createdFiles: [try writeAppID(appID, in: dir)])

        case .sharedSteamClient:
            guard let steamClientRoot, fileManager.fileExists(atPath: steamClientRoot.path) else {
                throw PresenceError.steamClientUnavailable
            }
            guard let prefix else { throw PresenceError.prefixRequired }
            var receipt = Receipt()
            let steamDest = PrefixLayout(prefix: prefix).driveC
                .appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
            try fileManager.createDirectory(
                at: steamDest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: steamDest.path) || isSymlink(steamDest) {
                try fileManager.removeItem(at: steamDest)
            }
            try fileManager.createSymbolicLink(at: steamDest, withDestinationURL: steamClientRoot)
            receipt.createdFiles.append(steamDest)
            receipt.createdFiles.append(try writeAppID(appID, in: dir))
            return receipt
        }
    }

    /// Undo a previously-applied receipt.
    public func revert(_ receipt: Receipt) throws {
        for file in receipt.createdFiles where fileManager.fileExists(atPath: file.path) || isSymlink(file) {
            try fileManager.removeItem(at: file)
        }
    }

    // MARK: - Helpers

    private func writeAppID(_ appID: Int, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("steam_appid.txt")
        try "\(appID)".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
