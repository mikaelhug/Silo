import Foundation

/// Finds a game's main `.exe` inside its install directory when the user hasn't pinned one.
public enum ExecutableResolver {
    /// First `.exe` under `installURL`: prefer one named like the install folder, else the largest.
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

        let target = installURL.lastPathComponent.lowercased()
        if let match = exes.first(where: {
            $0.deletingPathExtension().lastPathComponent.lowercased() == target
        }) {
            return match
        }
        return exes.max { size(of: $0, fileManager) < size(of: $1, fileManager) }
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
