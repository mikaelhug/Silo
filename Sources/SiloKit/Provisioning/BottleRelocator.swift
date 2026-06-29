import Foundation

/// Moves the bottle directories (`SteamBottle` + `ManualBottles`) from one root to another — e.g. when the
/// user relocates bottles to an external drive.
///
/// Same-volume moves are an instant rename. A **cross-volume** move is a manual byte-counting recursive
/// copy (preserving symlinks — a Wine prefix is full of them) so it can report progress, followed by
/// deleting the sources. Sources are removed only after EVERY directory has copied, so a failure leaves the
/// originals intact. Meant to be awaited off the main actor.
public struct BottleRelocator: Sendable {
    private var fileManager: FileManager { .default }

    public init() {}

    public enum RelocateError: Error, Sendable, Equatable {
        case sameLocation
        case destinationNotWritable(URL)
        case destinationOccupied(URL)        // dest already holds a bottle dir — refuse rather than merge
        case moveFailed(String)
    }

    /// Move each of `names` from `oldRoot` to `newRoot`, reporting copy progress in `0...1`.
    /// - Parameters:
    ///   - forceCopy: skip the same-volume rename fast path and always copy (used in tests).
    ///   - onProgress: cumulative fraction copied; only meaningful for a cross-volume copy.
    public func move(
        _ names: [String], from oldRoot: URL, to newRoot: URL,
        forceCopy: Bool = false,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else {
            throw RelocateError.sameLocation
        }
        try? fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: newRoot.path) else {
            throw RelocateError.destinationNotWritable(newRoot)
        }
        for name in names {
            let dest = newRoot.appendingPathComponent(name)
            if fileManager.fileExists(atPath: dest.path) { throw RelocateError.destinationOccupied(dest) }
        }

        let present = names.filter { fileManager.fileExists(atPath: oldRoot.appendingPathComponent($0).path) }

        if !forceCopy && sameVolume(oldRoot, newRoot) {
            try renameMove(present, from: oldRoot, to: newRoot)   // instant, atomic
            onProgress(1.0)
            return
        }
        try copyMove(present, from: oldRoot, to: newRoot, onProgress: onProgress)
        onProgress(1.0)
    }

    // MARK: - Same-volume (rename)

    private func renameMove(_ names: [String], from oldRoot: URL, to newRoot: URL) throws {
        var moved: [(src: URL, dst: URL)] = []
        for name in names {
            let src = oldRoot.appendingPathComponent(name), dst = newRoot.appendingPathComponent(name)
            do {
                try fileManager.moveItem(at: src, to: dst)
                moved.append((src, dst))
            } catch {
                for done in moved.reversed() { try? fileManager.moveItem(at: done.dst, to: done.src) }
                throw RelocateError.moveFailed((error as NSError).localizedDescription)
            }
        }
    }

    // MARK: - Cross-volume (copy + delete, with progress)

    private func copyMove(
        _ names: [String], from oldRoot: URL, to newRoot: URL, onProgress: @Sendable @escaping (Double) -> Void
    ) throws {
        let total = names.reduce(Int64(0)) { $0 + dirSize(oldRoot.appendingPathComponent($1)) }
        let progress = CopyProgress(total: total, onProgress: onProgress)
        var copied: [URL] = []
        for name in names {
            let src = oldRoot.appendingPathComponent(name), dst = newRoot.appendingPathComponent(name)
            do {
                try copyTree(from: src, to: dst, progress: progress)
                copied.append(dst)
            } catch {
                for dest in copied { try? fileManager.removeItem(at: dest) }   // roll back copies; sources intact
                try? fileManager.removeItem(at: dst)
                throw RelocateError.moveFailed((error as NSError).localizedDescription)
            }
        }
        // Every dir copied — now remove the originals (the "move" completes).
        for name in names { try? fileManager.removeItem(at: oldRoot.appendingPathComponent(name)) }
    }

    /// Recursively copy `src`→`dst`: symlinks are recreated (NOT dereferenced — a Wine prefix's
    /// `dosdevices`/profile links must survive), directories recursed, regular files copied (preserving
    /// attributes) and counted toward progress.
    private func copyTree(from src: URL, to dst: URL, progress: CopyProgress) throws {
        let info = try src.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if info.isSymbolicLink == true {
            let target = try fileManager.destinationOfSymbolicLink(atPath: src.path)
            try fileManager.createSymbolicLink(atPath: dst.path, withDestinationPath: target)
            return
        }
        if info.isDirectory == true {
            try fileManager.createDirectory(at: dst, withIntermediateDirectories: true)
            for child in try fileManager.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: []) {
                try copyTree(from: child, to: dst.appendingPathComponent(child.lastPathComponent), progress: progress)
            }
            return
        }
        try fileManager.copyItem(at: src, to: dst)
        progress.add(fileSize(src))
    }

    // MARK: - Helpers

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            var u = url   // a brand-new newRoot may not exist yet — walk up to its first existing ancestor
            while !fileManager.fileExists(atPath: u.path) && u.pathComponents.count > 1 {
                u = u.deletingLastPathComponent()
            }
            return (try? u.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va.isEqual(vb)
    }

    private func dirSize(_ url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            if let v = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

/// Accumulates copied bytes and emits a throttled `0...1` fraction. Confined to a single (synchronous)
/// copy walk, so it never crosses a concurrency boundary.
private final class CopyProgress {
    private let total: Int64
    private let onProgress: @Sendable (Double) -> Void
    private var copied: Int64 = 0
    private var lastReported = 0.0

    init(total: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    func add(_ bytes: Int64) {
        copied += bytes
        let fraction = total > 0 ? min(1.0, Double(copied) / Double(total)) : 1.0
        if fraction - lastReported >= 0.005 || fraction >= 1.0 {   // throttle to ~every 0.5%
            lastReported = fraction
            onProgress(fraction)
        }
    }
}
