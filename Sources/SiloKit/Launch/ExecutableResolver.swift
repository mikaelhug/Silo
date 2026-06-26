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
}
