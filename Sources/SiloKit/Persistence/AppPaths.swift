import Foundation

/// Canonical filesystem locations. App state (config, logs, runtimes) lives under
/// `~/Library/Application Support/Silo`; the **bottles** (Steam + manual) live under `bottlesRoot`, which
/// defaults to `supportDir` but can be relocated to another disk / external drive.
public struct AppPaths: Sendable, Hashable {
    public let supportDir: URL
    /// The folder that holds the bottle prefixes (`SteamBottle` + `ManualBottles`). Defaults to
    /// `supportDir`; the user can move it elsewhere (persisted via `BottlesLocation`, read at startup so
    /// every derived path points at the right place from the first frame).
    public let bottlesRoot: URL

    public init(supportDir: URL, bottlesRoot: URL? = nil) {
        self.supportDir = supportDir
        self.bottlesRoot = bottlesRoot ?? supportDir
    }

    /// The standard location under the user's Application Support directory, honouring a persisted
    /// bottles-location override.
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Silo", isDirectory: true)
        return AppPaths(supportDir: base, bottlesRoot: BottlesLocation.read(supportDir: base))
    }

    public var runtimesDir: URL { supportDir.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDir: URL { supportDir.appendingPathComponent("Logs", isDirectory: true) }
    public var configFile: URL { supportDir.appendingPathComponent("config.json") }
    /// Scratch dir for downloaded app-update archives (the inline updater stages the `.zip` here).
    public var updatesDir: URL { supportDir.appendingPathComponent("Updates", isDirectory: true) }
    /// Temp dir for a setup run's artifact downloads (`SetupDownloads`) — under `supportDir` so downloads can
    /// start the moment "Set up" is pressed, BEFORE the bottle prefix / its `drive_c` exists. NOT a cache: it's
    /// wiped at the start of every run and removed when setup finishes, so a stale installer is never reused.
    public var setupDownloadsTmp: URL { supportDir.appendingPathComponent("SetupDownloads", isDirectory: true) }

    // MARK: - Bottles location

    /// Bottles live somewhere other than the default (Application Support).
    public var bottlesRelocated: Bool {
        bottlesRoot.standardizedFileURL != supportDir.standardizedFileURL
    }

    /// Whether the configured bottles root is currently usable — its volume is mounted. (A custom root on
    /// an external drive becomes unreachable when the drive is ejected.) The root itself need not exist yet
    /// (a fresh custom location), only its parent.
    public var bottlesRootReachable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: bottlesRoot.path)
            || fm.fileExists(atPath: bottlesRoot.deletingLastPathComponent().path)
    }

    /// The bottle directory names that relocate together (everything under `bottlesRoot`): the single shared
    /// Steam bottle plus the manual-games parent.
    public static let bottleDirNames = ["SteamBottle", "ManualBottles"]

    // MARK: - Steam bottle (one shared prefix hosting the Steam client + its games)

    /// The shared Wine prefix — the Steam client + its games co-resident under GPTK/D3DMetal. Historically
    /// named `SteamBottle`.
    public var steamBottle: URL { bottlesRoot.appendingPathComponent("SteamBottle", isDirectory: true) }

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
    public var steamBottleCEFDir: URL { steamBottleClientDir.appendingPathComponent("bin/cef") }

    /// The Steam bottle's client log.
    public var steamBottleLog: URL { logsDir.appendingPathComponent("steam-bottle.log") }

    /// Parent of the per-game isolated bottles used by manual (non-Steam) games.
    public var manualBottlesDir: URL { bottlesRoot.appendingPathComponent("ManualBottles", isDirectory: true) }

    /// A manual game's own isolated Wine prefix (its private registry + `drive_c`), keyed by its id.
    public func manualBottle(_ id: UUID) -> URL {
        manualBottlesDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Per-game launch log file (`<appID>.log`).
    public func log(forAppID appID: Int) -> URL {
        logsDir.appendingPathComponent("\(appID).log")
    }

    /// Launch log for a manual (non-Steam) game, keyed by its stable id.
    public func manualLog(_ id: UUID) -> URL {
        logsDir.appendingPathComponent("manual-\(id.uuidString).log")
    }
}
