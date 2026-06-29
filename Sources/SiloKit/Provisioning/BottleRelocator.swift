import Foundation

/// Moves the bottle directories (`SteamBottle` + `ManualBottles`) from one root to another — e.g. when the
/// user relocates bottles to an external drive. A cross-volume move is a copy-then-delete (slow for large
/// installs), so this is meant to be awaited off the main actor.
public struct BottleRelocator: Sendable {
    private var fileManager: FileManager { .default }

    public init() {}

    public enum RelocateError: Error, Sendable, Equatable {
        case sameLocation
        case destinationNotWritable(URL)
        case destinationOccupied(URL)        // dest already holds a bottle dir — refuse rather than merge
        case moveFailed(String)
    }

    /// Move each of `names` from `oldRoot` to `newRoot`. Pre-checks the destination is writable and not
    /// already occupied; a per-directory failure rolls back everything already moved so we never end up
    /// half-relocated. Directories absent in `oldRoot` are simply skipped.
    public func move(_ names: [String], from oldRoot: URL, to newRoot: URL) async throws {
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else {
            throw RelocateError.sameLocation
        }
        try? fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: newRoot.path) else {
            throw RelocateError.destinationNotWritable(newRoot)
        }
        // Refuse if the destination already carries any of the bottle dirs (don't clobber/merge).
        for name in names {
            let dest = newRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: dest.path) { throw RelocateError.destinationOccupied(dest) }
        }

        var moved: [(src: URL, dst: URL)] = []
        for name in names {
            let src = oldRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }   // nothing here to move
            let dst = newRoot.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: src, to: dst)
                moved.append((src, dst))
            } catch {
                // Roll back: drop any partial copy at `dst`, then return the already-moved dirs home.
                try? fileManager.removeItem(at: dst)
                for done in moved.reversed() { try? fileManager.moveItem(at: done.dst, to: done.src) }
                throw RelocateError.moveFailed((error as NSError).localizedDescription)
            }
        }
    }
}
