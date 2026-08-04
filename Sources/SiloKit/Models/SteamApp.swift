import Foundation

/// A Steam game discovered from the Steam bottle's `appmanifest_*.acf`.
public struct SteamApp: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }

    public let appID: Int
    public let name: String
    /// Folder name under `<library>/steamapps/common/`.
    public let installDir: String
    public let stateFlags: StateFlags
    public let sizeOnDisk: Int64
    public let bytesDownloaded: Int64?
    public let bytesToDownload: Int64?
    public let buildID: Int?
    public let lastUpdated: Date?
    /// Steam's `LastOwner` — the SteamID64 of the account that owns/installed this app. Steam writes `0`
    /// for the shared system packages it auto-installs (Steamworks Common Redistributables, runtimes,
    /// tools) rather than games the user owns. Used to keep those out of the library.
    public let lastOwner: Int64?
    /// The library-folder root this app belongs to (derived during discovery, not from the .acf).
    public let libraryPath: URL

    public init(
        appID: Int,
        name: String,
        installDir: String,
        stateFlags: StateFlags,
        sizeOnDisk: Int64,
        bytesDownloaded: Int64? = nil,
        bytesToDownload: Int64? = nil,
        buildID: Int? = nil,
        lastUpdated: Date? = nil,
        lastOwner: Int64? = nil,
        libraryPath: URL
    ) {
        self.appID = appID
        self.name = name
        self.installDir = installDir
        self.stateFlags = stateFlags
        self.sizeOnDisk = sizeOnDisk
        self.bytesDownloaded = bytesDownloaded
        self.bytesToDownload = bytesToDownload
        self.buildID = buildID
        self.lastUpdated = lastUpdated
        self.lastOwner = lastOwner
        self.libraryPath = libraryPath
    }

    public var isFullyInstalled: Bool { stateFlags.isFullyInstalled }

    /// Shared packages Steam auto-installs alongside games (redistributables/runtimes). Not games, so the
    /// library hides them. **An explicit appID set, deliberately** — every heuristic tried against real
    /// manifests was wrong in at least one direction:
    /// - `LastOwner == 0` (what this used to be) simply never fires: 228980's manifest carries the real
    ///   owner's SteamID64, so the redistributable always surfaced as a game.
    /// - Executable presence fails BOTH ways: "Steamworks Shared" ships 5 `.exe` redist installers, while
    ///   Split Fiction has none above depth 2 — the check would keep the package and hide the game.
    /// - An empty `UserConfig` (no `language`) does separate them today, but it's a side effect of never
    ///   having been launched, so it risks hiding a freshly-installed game — and hiding a real game is far
    ///   worse than showing one package.
    /// An appID is stable, unique and unlocalised, so this is exact. 228980 is the only shared package Steam
    /// installs into a Windows bottle (the Linux runtimes never appear here).
    public static let sharedSystemAppIDs: Set<Int> = [
        228980,   // Steamworks Common Redistributables
    ]

    public var isSharedSystemApp: Bool { Self.sharedSystemAppIDs.contains(appID) }

    /// Library cover art (Steam CDN `header.jpg`).
    public var headerArtURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }
    /// Public Steam store page.
    public var storePageURL: URL? { URL(string: "https://store.steampowered.com/app/\(appID)") }

    /// Absolute on-disk install directory: `<library>/steamapps/common/<installDir>`.
    public var installURL: URL {
        libraryPath
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(installDir, isDirectory: true)
    }
}
