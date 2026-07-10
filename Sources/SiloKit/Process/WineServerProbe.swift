import Foundation

/// PID-free liveness for a Wine bottle: whether a `wineserver` is currently serving a given prefix.
///
/// Wine keeps one `wineserver` per prefix and exposes it as a Unix-domain socket in a per-user temp dir,
/// under a directory named from the prefix's `(st_dev, st_ino)` — the exact identity `wineserver` itself
/// uses to locate its socket. So "is this bottle live?" == "does that socket exist?", answerable with a
/// `stat` and NO tracked PID. This is how Silo guards a bottle move / self-update after dropping the PID
/// ledger: a launched game or Steam client — even one orphaned by a hard crash — leaves its wineserver
/// socket behind, so the gate still refuses to move a prefix out from under a live server (which corrupts it).
/// It's also how Silo can now QUIT while leaving Steam running — it no longer needs to own the PID to reason
/// about the bottle.
///
/// Fail-open: any failure to resolve the path reports NOT live, so a probe glitch can never wedge the user
/// out of moving bottles or updating. The temp root Wine uses is build-dependent (upstream `/tmp`, some
/// builds honor `$TMPDIR`/`$XDG_RUNTIME_DIR`), so every plausible root is probed — verify on-device which one
/// this runtime actually uses (see STATUS).
public enum WineServerProbe {
    /// Whether a `wineserver` is live for `prefix` right now.
    public static func isLive(prefix: URL, fileManager: FileManager = .default) -> Bool {
        guard let dirName = serverDirName(for: prefix) else { return false }
        let uid = getuid()
        for root in candidateRoots() {
            let socket = root
                .appendingPathComponent(".wine-\(uid)", isDirectory: true)
                .appendingPathComponent(dirName, isDirectory: true)
                .appendingPathComponent("socket")
            // Require the SOCKET file, not just the dir — the dir can linger after the server exits.
            if fileManager.fileExists(atPath: socket.path) { return true }
        }
        return false
    }

    /// Whether ANY Silo bottle (the shared Steam bottle or any manual bottle) has a live wineserver — the
    /// relocation/update gate, since a move relocates them all together.
    public static func isAnyBottleLive(paths: AppPaths, fileManager: FileManager = .default) -> Bool {
        if isLive(prefix: paths.steamBottle, fileManager: fileManager) { return true }
        let manual = (try? fileManager.contentsOfDirectory(
            at: paths.manualBottlesDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return manual.contains { isLive(prefix: $0, fileManager: fileManager) }
    }

    /// `server-<dev>-<ino>` (lowercase hex, matching Wine's own `%llx-%llx` naming) for the prefix dir, or
    /// nil if it can't be `stat`'d (a not-yet-created bottle → never live).
    static func serverDirName(for prefix: URL) -> String? {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return nil }
        // Wine formats `(unsigned long long)st_dev` / `st_ino`; match that bit-for-bit.
        let dev = UInt64(bitPattern: Int64(info.st_dev))
        return "server-\(String(dev, radix: 16))-\(String(info.st_ino, radix: 16))"
    }

    /// The temp roots to probe for the wineserver socket, most-specific first, de-duplicated.
    private static func candidateRoots() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var raw: [String] = []
        if let x = env["XDG_RUNTIME_DIR"], !x.isEmpty { raw.append(x) }
        if let t = env["TMPDIR"], !t.isEmpty { raw.append(t) }
        raw.append("/tmp")
        var seen = Set<String>()
        return raw.compactMap { path in
            let norm = (path as NSString).standardizingPath
            guard seen.insert(norm).inserted else { return nil }
            return URL(fileURLWithPath: norm, isDirectory: true)
        }
    }
}
