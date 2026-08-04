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

    /// First `.exe` under `installURL`: prefer one named like the install folder, else the largest —
    /// **ignoring bundled redistributables/installers**, which are often the biggest `.exe` present.
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
        return pool.max { size(of: $0, fileManager) < size(of: $1, fileManager) }
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
