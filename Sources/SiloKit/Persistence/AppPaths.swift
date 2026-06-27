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

    public var prefixesDir: URL { supportDir.appendingPathComponent("Prefixes", isDirectory: true) }
    public var runtimesDir: URL { supportDir.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDir: URL { supportDir.appendingPathComponent("Logs", isDirectory: true) }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }

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

    /// The native **macOS** Steam client's data dir — the source for seeding a login into the bottle.
    /// (`~/Library/Application Support/Steam`, a sibling of Silo's own support dir.)
    public var macSteamDir: URL {
        supportDir.deletingLastPathComponent().appendingPathComponent("Steam", isDirectory: true)
    }

    /// The bottle's Steam log.
    public var steamBottleLog: URL { logsDir.appendingPathComponent("steam-bottle.log") }

    /// Native macOS SteamCMD install dir + its bootstrap script.
    public var steamCMDDir: URL { supportDir.appendingPathComponent("SteamCMD", isDirectory: true) }
    public var steamCMDScript: URL { steamCMDDir.appendingPathComponent("steamcmd.sh") }

    /// Library root where SteamCMD installs the downloaded Windows games (parsed by DiscoveryEngine as
    /// a Steam library: `<root>/steamapps/appmanifest_*.acf`).
    public var gameLibraryDir: URL { supportDir.appendingPathComponent("GameLibrary", isDirectory: true) }

    /// Per-game install dir under the game library (SteamCMD `force_install_dir` target).
    public func gameInstallDir(forAppID appID: Int) -> URL {
        gameLibraryDir.appendingPathComponent("steamapps/common/\(appID)", isDirectory: true)
    }

    /// Isolated Wine prefix root for a game.
    public func prefix(forAppID appID: Int) -> URL {
        prefixesDir.appendingPathComponent("\(appID)", isDirectory: true)
    }

    /// Per-game launch log file.
    public func log(forAppID appID: Int) -> URL {
        logsDir.appendingPathComponent("\(appID).log")
    }
}
