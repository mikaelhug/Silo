import Foundation

/// Canonical filesystem locations under `~/Library/Application Support/Silo`.
public struct AppPaths: Sendable, Hashable {
    public let supportDir: URL

    public init(supportDir: URL) {
        self.supportDir = supportDir
    }

    /// The standard location under the user's Application Support directory.
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Silo", isDirectory: true)
        return AppPaths(supportDir: base)
    }

    public var runtimesDir: URL { supportDir.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDir: URL { supportDir.appendingPathComponent("Logs", isDirectory: true) }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }
    /// Scratch dir for downloaded app-update archives (the inline updater stages the `.zip` here).
    public var updatesDir: URL { supportDir.appendingPathComponent("Updates", isDirectory: true) }

    // MARK: - Steam bottle (the shared prefix that hosts a logged-in Windows Steam client + its games)

    /// The single shared Wine prefix that runs the Windows Steam client and the games co-resident with it.
    public var steamBottle: URL { supportDir.appendingPathComponent("SteamBottle", isDirectory: true) }

    /// The Windows Steam install inside the bottle (`drive_c/Program Files (x86)/Steam`).
    public var steamBottleClientDir: URL {
        steamBottle
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
    }

    /// `steam.exe` inside the bottle.
    public var steamBottleExe: URL { steamBottleClientDir.appendingPathComponent("steam.exe") }

    /// The directory holding Steam's CEF binaries inside the bottle. The leaf name varies by Steam version
    /// (currently `cef.win7x64`), so callers that need the exact `steamwebhelper.exe` glob this dir's
    /// children rather than assume the leaf — see `SteamBottle.webHelpers()`.
    public var steamBottleCEFDir: URL {
        steamBottleClientDir.appendingPathComponent("bin/cef")
    }

    /// The bottle's Steam log.
    public var steamBottleLog: URL { logsDir.appendingPathComponent("steam-bottle.log") }

    /// Per-game launch log file.
    public func log(forAppID appID: Int) -> URL {
        logsDir.appendingPathComponent("\(appID).log")
    }

    /// Launch log for a manual (non-Steam) game, keyed by its stable id.
    public func manualLog(_ id: UUID) -> URL {
        logsDir.appendingPathComponent("manual-\(id.uuidString).log")
    }
}
