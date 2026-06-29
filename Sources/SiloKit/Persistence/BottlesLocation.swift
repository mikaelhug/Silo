import Foundation

/// Persists the user's chosen **bottles root** — the folder that holds `SteamBottle` + `ManualBottles`.
/// Stored as a plain absolute path in a tiny file under `supportDir`, deliberately SEPARATE from
/// `config.json` so it can be read **synchronously at startup** (before the async config loads) to build
/// `AppPaths` with the right `bottlesRoot` from the first frame.
enum BottlesLocation {
    /// `supportDir/bottles-location` — a one-line file holding the absolute path (absent = default).
    static func file(supportDir: URL) -> URL {
        supportDir.appendingPathComponent("bottles-location")
    }

    /// The persisted bottles root, or `nil` if none is set / the file is unreadable (→ default to
    /// `supportDir`). Does not validate that the path is currently reachable.
    static func read(supportDir: URL) -> URL? {
        guard let raw = try? String(contentsOf: file(supportDir: supportDir), encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Persist the bottles root (`nil` clears the override → back to the default). Best-effort.
    static func write(_ root: URL?, supportDir: URL) {
        let target = file(supportDir: supportDir)
        guard let root else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? root.standardizedFileURL.path.write(to: target, atomically: true, encoding: .utf8)
    }
}
