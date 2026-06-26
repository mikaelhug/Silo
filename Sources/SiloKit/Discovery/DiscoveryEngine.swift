import Foundation

/// Scans a Master Steam bottle for downloaded games.
///
/// Reads the primary `steamapps` directory plus any additional libraries listed in
/// `libraryfolders.vdf`, parses every `appmanifest_*.acf`, and returns the games sorted by name.
/// Unparseable manifests and missing extra libraries are skipped rather than failing the whole scan.
public actor DiscoveryEngine {
    private let fileManager: FileManager
    private let manifestDecoder = AppManifestDecoder()
    private let libraryDecoder = LibraryFoldersDecoder()

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public enum DiscoveryError: Error, Sendable, Equatable {
        case steamDirNotFound(URL)
    }

    /// The Steam install directory inside a Wine bottle (the dir containing `steamapps/`).
    public nonisolated static func steamRoot(inBottle bottle: URL) -> URL {
        bottle
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
    }

    /// Discover all games reachable from `steamRoot` (the primary Steam install directory).
    public func discoverGames(steamRoot: URL) throws -> [SteamApp] {
        let primarySteamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        guard fileManager.fileExists(atPath: primarySteamapps.path) else {
            throw DiscoveryError.steamDirNotFound(primarySteamapps)
        }

        let libraryRoots = collectLibraryRoots(primarySteamRoot: steamRoot, primarySteamapps: primarySteamapps)

        var apps: [SteamApp] = []
        var seen = Set<Int>()
        for root in libraryRoots {
            for app in scanLibrary(root: root) where seen.insert(app.appID).inserted {
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Internals

    /// Primary library + any host-absolute paths from `libraryfolders.vdf`, de-duplicated.
    /// (Windows-style paths from a Wine bottle are skipped for now — games in the single-downloader
    /// model land in the primary C: library; cross-drive translation is a documented follow-up.)
    private func collectLibraryRoots(primarySteamRoot: URL, primarySteamapps: URL) -> [URL] {
        var roots: [URL] = [primarySteamRoot]
        var seenPaths = Set([primarySteamRoot.standardizedFileURL.path])

        let vdf = primarySteamapps.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let folders = try? libraryDecoder.decode(text: text) {
            for folder in folders where folder.path.path.hasPrefix("/") {
                let standardized = folder.path.standardizedFileURL
                if seenPaths.insert(standardized.path).inserted {
                    roots.append(standardized)
                }
            }
        }
        return roots
    }

    private func scanLibrary(root: URL) -> [SteamApp] {
        let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: steamapps, includingPropertiesForKeys: nil
        ) else { return [] }

        var apps: [SteamApp] = []
        for entry in entries
        where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
            guard let text = try? String(contentsOf: entry, encoding: .utf8),
                  let app = try? manifestDecoder.decode(text: text, libraryPath: root) else { continue }
            apps.append(app)
        }
        return apps
    }
}
