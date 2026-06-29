import Foundation

/// Parses a Steam library root (the Steam bottle's `steamapps`) for installed games.
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

    /// Discover all games reachable from `steamRoot` (the primary Steam install directory).
    public func discoverGames(steamRoot: URL) throws -> [SteamApp] {
        let primarySteamapps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        guard fileManager.fileExists(atPath: primarySteamapps.path) else {
            throw DiscoveryError.steamDirNotFound(primarySteamapps)
        }

        let libraryRoots = collectLibraryRoots(primarySteamRoot: steamRoot)

        var apps: [SteamApp] = []
        var seen = Set<Int>()
        for root in libraryRoots {
            // Skip shared system packages (Steamworks Common Redistributables, runtimes, tools): Steam
            // installs them with `LastOwner == 0`, so they aren't games — see `SteamApp.isSharedSystemApp`.
            for app in scanLibrary(root: root)
            where !app.isSharedSystemApp && seen.insert(app.appID).inserted {
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Internals

    /// Primary library + any host-absolute paths from `libraryfolders.vdf`, de-duplicated.
    /// (Windows-style paths from a Wine bottle are skipped for now — games in the single-downloader
    /// model land in the primary C: library; cross-drive translation is a documented follow-up.)
    private func collectLibraryRoots(primarySteamRoot: URL) -> [URL] {
        var roots: [URL] = [primarySteamRoot]
        var seenPaths = Set([primarySteamRoot.standardizedFileURL.path])

        let steamapps = primarySteamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let vdf = steamapps.appendingPathComponent("libraryfolders.vdf")
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
            // Skip a pathologically large file: the tokenizer reads the whole manifest into memory, and a
            // real appmanifest is a few KB — anything over the cap isn't a manifest worth parsing.
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxManifestBytes else { continue }
            guard let text = try? String(contentsOf: entry, encoding: .utf8),
                  let app = try? manifestDecoder.decode(text: text, libraryPath: root) else { continue }
            apps.append(app)
        }
        return apps
    }

    /// Upper bound on an `appmanifest_*.acf` we'll read (real ones are a few KB; 8 MB is far beyond any
    /// legitimate manifest) — bounds the tokenizer's whole-file allocation against a hostile local file.
    private static let maxManifestBytes = 8 * 1024 * 1024
}
