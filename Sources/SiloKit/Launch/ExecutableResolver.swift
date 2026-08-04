import Foundation

/// Finds a game's main `.exe` inside its install directory when the user hasn't pinned one.
public enum ExecutableResolver {
    /// Directory names holding redistributables/prerequisites rather than the game.
    private static let excludedDirs: Set<String> = [
        "_commonredist", "commonredist", "redist", "_redist", "redistributables",
        "directx", "dotnet", "dotnetfx", "vcredist", "installers", "prerequisites",
    ]
    /// Filename prefixes of bundled installers/helpers that are never the game. Load-bearing for the
    /// "largest exe" tie-break: a Steam install routinely ships `VC_redist.x64.exe` (~25 MB) or
    /// `UEPrereqSetup_x64.exe`, which would otherwise WIN the size contest and become "the game" — poisoning
    /// both the bitness read (→ wrong backend) and the `D3DProfile` scan rooted at its directory.
    private static let excludedNamePrefixes = [
        "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx", "ueprereqsetup", "uepreqsetup",
        "unitycrashhandler", "crashreportclient", "unins", "dotnetfx", "oalinst", "steamworksshared",
        // Source's DEDICATED SERVER, shipped beside the game by every Source title and — in Alien Swarm —
        // larger than the game's own launcher (`srcds.exe` 86 KB vs `swarm.exe` 78 KB), so it won the size
        // tie-break at the same depth and got launched instead of the game.
        "srcds",
    ]

    /// Whether `url` is a bundled redistributable/helper rather than a game executable — by its own name or
    /// by sitting inside a redist directory.
    static func isAuxiliaryExecutable(_ url: URL, relativeTo installURL: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if excludedNamePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        let base = installURL.standardizedFileURL.path
        let path = url.standardizedFileURL.deletingLastPathComponent().path
        guard path.hasPrefix(base) else { return false }
        let components = String(path.dropFirst(base.count)).split(separator: "/").map { $0.lowercased() }
        return components.contains { excludedDirs.contains($0) }
    }

    /// Depth of `url` below `installURL` in path components — 0 for an exe sitting at the install root.
    /// Returns `Int.max` for anything outside the tree, so it sorts last rather than being mistaken for root.
    static func depth(of url: URL, relativeTo installURL: URL) -> Int {
        let base = installURL.standardizedFileURL.path
        let path = url.standardizedFileURL.deletingLastPathComponent().path
        guard path.hasPrefix(base) else { return .max }
        return String(path.dropFirst(base.count)).split(separator: "/").count
    }

    /// First `.exe` under `installURL`: prefer one named like the install folder, then the SHALLOWEST, and
    /// only then the largest — **ignoring bundled redistributables/installers**, which are often the biggest
    /// `.exe` present.
    ///
    /// Depth beats size because a game's launcher is routinely a small stub at the install root while the
    /// biggest binaries are engine tooling buried in a subdirectory. Every free Source title tested launched
    /// the WRONG program without this: `bin/elementviewer.exe` (3.2 MB, a model viewer) outweighed the real
    /// `hl2.exe` at the root, so Transmissions: Element 120 and Double Action: Boogaloo both "launched" a
    /// tool that exits immediately, and Alien Swarm ran `bin/addoninstaller.exe`. `allExecutables` below has
    /// always sorted shallowest-first for exactly this reason ("deep ones tend to be redistributables") —
    /// this function simply never applied the same rule.
    public static func firstExecutable(in installURL: URL, fileManager: FileManager = .default) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: installURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var exes: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "exe" {
            exes.append(url)
        }
        guard !exes.isEmpty else { return nil }
        // Drop redists/installers, but fail open: if that leaves nothing, fall back to the full list rather
        // than resolving no executable at all.
        let candidates = exes.filter { !isAuxiliaryExecutable($0, relativeTo: installURL) }
        let pool = candidates.isEmpty ? exes : candidates

        let target = installURL.lastPathComponent.lowercased()
        if let match = pool.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == target
        }) {
            return match
        }
        // Shallowest first; largest only among equals. (Split Fiction's real exe sits three levels down, so
        // this must compare depth *within the surviving pool* — never assume the game is at the root.)
        guard let shallowest = pool.map({ depth(of: $0, relativeTo: installURL) }).min() else { return nil }
        return pool
            .filter { depth(of: $0, relativeTo: installURL) == shallowest }
            .max { size(of: $0, fileManager) < size(of: $1, fileManager) }
    }

    private static func size(of url: URL, _ fileManager: FileManager) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// All `.exe` paths under `installURL`, relative to it, shallowest first (the main exe is usually
    /// top-level; deep ones tend to be redistributables). For the per-game executable picker.
    public static func allExecutables(in installURL: URL, fileManager: FileManager = .default) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: installURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = installURL.standardizedFileURL.path
        var relatives: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "exe" {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base + "/") { relatives.append(String(path.dropFirst(base.count + 1))) }
        }
        return relatives.sorted {
            let da = $0.filter { $0 == "/" }.count, db = $1.filter { $0 == "/" }.count
            return da == db ? $0.localizedCaseInsensitiveCompare($1) == .orderedAscending : da < db
        }
    }
}
