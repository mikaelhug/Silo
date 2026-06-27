import Foundation

/// Applies a `SteamPresenceStrategy` for a game and produces a reversible `Receipt`.
///
/// Safety: never downloads or bundles any binary. The `.emulatorStub` strategy only copies a
/// **user-provided** stub, backing up the original DLL first. The UI must show a legal/ToS caveat.
public struct SteamPresenceInstaller: Sendable {
    public init() {}
    private var fileManager: FileManager { .default }

    public enum PresenceError: Error, Sendable, Equatable {
        case stubNotProvided
        case stubMissing(URL)
        case steamClientUnavailable
        case prefixRequired
    }

    public struct Backup: Codable, Sendable, Equatable {
        public let original: URL
        public let backup: URL
    }

    /// Records what was changed so it can be undone.
    public struct Receipt: Codable, Sendable, Equatable {
        public var createdFiles: [URL] = []
        public var backups: [Backup] = []
    }

    /// Apply the strategy. `gameExe` locates the install dir; `prefix` and `masterSteamRoot` are
    /// only needed for `.sharedSteamClient`; `stubSource` only for `.emulatorStub`.
    @discardableResult
    public func apply(
        strategy: SteamPresenceStrategy,
        appID: Int,
        gameExe: URL,
        stubSource: URL? = nil,
        masterSteamRoot: URL? = nil,
        prefix: URL? = nil
    ) throws -> Receipt {
        let dir = gameExe.deletingLastPathComponent()

        switch strategy {
        case .none:
            return Receipt()

        case .steamAppIDFile:
            return Receipt(createdFiles: [try writeAppID(appID, in: dir)])

        case .emulatorStub:
            guard let stubSource else { throw PresenceError.stubNotProvided }
            guard fileManager.fileExists(atPath: stubSource.path) else {
                throw PresenceError.stubMissing(stubSource)
            }
            var receipt = Receipt()
            // Replace EVERY copy of the game's Steam-API DLL in the install tree. Electron/Unity/etc. ship
            // it in a subdir (e.g. resources/app.asar.unpacked/.../win64/steam_api64.dll), where a stub
            // merely dropped next to the exe would never be loaded. If the game ships none, place one next
            // to the exe (the game must then load it from there).
            var targets = locateFiles(named: stubSource.lastPathComponent, under: dir)
            if targets.isEmpty { targets = [dir.appendingPathComponent(stubSource.lastPathComponent)] }
            for dest in targets { try installStub(stubSource, at: dest, into: &receipt) }
            receipt.createdFiles.append(try writeAppID(appID, in: dir))
            return receipt

        case .sharedSteamClient:
            guard let masterSteamRoot, fileManager.fileExists(atPath: masterSteamRoot.path) else {
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
            try fileManager.createSymbolicLink(at: steamDest, withDestinationURL: masterSteamRoot)
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
        for backup in receipt.backups {
            if fileManager.fileExists(atPath: backup.original.path) {
                try fileManager.removeItem(at: backup.original)
            }
            if fileManager.fileExists(atPath: backup.backup.path) {
                try fileManager.moveItem(at: backup.backup, to: backup.original)
            }
        }
    }

    // MARK: - Helpers

    /// Copy `stub` over `dest`, backing up a pre-existing original exactly once. Idempotent: never
    /// "backs up" our own stub and never overwrites an existing backup (which would lose the real DLL).
    private func installStub(_ stub: URL, at dest: URL, into receipt: inout Receipt) throws {
        let destExists = fileManager.fileExists(atPath: dest.path)
        if destExists && fileManager.contentsEqual(atPath: dest.path, andPath: stub.path) { return }
        if destExists {
            let backup = dest.appendingPathExtension("silo-backup")
            if !fileManager.fileExists(atPath: backup.path) { try fileManager.copyItem(at: dest, to: backup) }
            try fileManager.removeItem(at: dest)
            receipt.backups.append(Backup(original: dest, backup: backup))
        } else {
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            receipt.createdFiles.append(dest)
        }
        try fileManager.copyItem(at: stub, to: dest)
    }

    /// Every file named `name` under `root` (bounded recursion so a huge game tree isn't fully walked).
    private func locateFiles(named name: String, under root: URL, maxDepth: Int = 12) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level >= maxDepth { enumerator.skipDescendants() }
            if url.lastPathComponent == name { found.append(url) }
        }
        return found
    }

    private func writeAppID(_ appID: Int, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("steam_appid.txt")
        try "\(appID)".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
