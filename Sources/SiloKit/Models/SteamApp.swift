import Foundation

/// A Steam game discovered from a Master-bottle `appmanifest_*.acf`.
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
        self.libraryPath = libraryPath
    }

    public var isFullyInstalled: Bool { stateFlags.isFullyInstalled }
    public var needsUpdate: Bool { stateFlags.needsUpdate }

    /// Steam CDN header artwork (460×215) for the game card. Public, no auth.
    public var headerArtURL: URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    /// Download progress in `0...1` while a download is active, else `nil`.
    public var downloadProgress: Double? {
        guard let total = bytesToDownload, total > 0, let done = bytesDownloaded else { return nil }
        return min(1.0, max(0.0, Double(done) / Double(total)))
    }

    /// Absolute on-disk install directory: `<library>/steamapps/common/<installDir>`.
    public var installURL: URL {
        libraryPath
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(installDir, isDirectory: true)
    }
}
