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

    /// The bottle directory names that relocate together (everything under `bottlesRoot`). One shared
    /// Steam bottle per graphics backend (GPTK keeps the historical `SteamBottle`; DXMT is a sibling) plus
    /// the manual-games parent.
    public static let bottleDirNames = ["SteamBottle", "SteamBottle-DXMT", "ManualBottles"]

    // MARK: - Steam bottles (one shared prefix per backend, each hosting a Steam client + its games)

    /// A backend's shared Wine prefix — the Steam client + games co-resident under that backend's runtime.
    /// GPTK and DXMT can't share a runtime/wineserver, so each backend gets its own bottle. GPTK (the
    /// default) keeps the historical `SteamBottle` directory so the existing prefix needs no migration; a
    /// secondary backend gets a suffixed sibling (`SteamBottle-DXMT`).
    public func steamBottle(_ backend: GraphicsBackend) -> URL {
        let name = backend == .gptk ? "SteamBottle" : "SteamBottle-\(backend.badge)"
        return bottlesRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// The Windows Steam install inside a backend's bottle (`drive_c/Program Files (x86)/Steam`).
    public func steamBottleClientDir(_ backend: GraphicsBackend) -> URL {
        steamBottle(backend)
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
    }

    /// `steam.exe` inside a backend's bottle.
    public func steamBottleExe(_ backend: GraphicsBackend) -> URL {
        steamBottleClientDir(backend).appendingPathComponent("steam.exe")
    }

    /// The directory holding Steam's CEF binaries inside a backend's bottle. The leaf name varies by Steam
    /// version (currently `cef.win7x64`), so callers that need the exact `steamwebhelper.exe` glob this
    /// dir's children rather than assume the leaf — see `SteamBottle.webHelpers()`.
    public func steamBottleCEFDir(_ backend: GraphicsBackend) -> URL {
        steamBottleClientDir(backend).appendingPathComponent("bin/cef")
    }

    /// A backend's Steam log (`steam-bottle.log` for GPTK, `steam-bottle-dxmt.log` for DXMT).
    public func steamBottleLog(_ backend: GraphicsBackend) -> URL {
        let name = backend == .gptk ? "steam-bottle.log" : "steam-bottle-\(backend.rawValue).log"
        return logsDir.appendingPathComponent(name)
    }

    /// Parent of the per-game isolated bottles used by manual (non-Steam) games.
    public var manualBottlesDir: URL { bottlesRoot.appendingPathComponent("ManualBottles", isDirectory: true) }

    /// A manual game's own isolated Wine prefix (its private registry + `drive_c`), keyed by its id.
    public func manualBottle(_ id: UUID) -> URL {
        manualBottlesDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Per-game launch log file, scoped to the graphics backend the copy runs under. The SAME title can be
    /// installed in BOTH the GPTK and DXMT bottles and launched independently, so an appID-only log would
    /// let the two copies clobber each other's log (and confuse the graphics-fallback watcher that tails
    /// it). GPTK keeps the plain `<appID>.log` (back-compat); DXMT gets `<appID>-dxmt.log`, mirroring
    /// `steamBottleLog`.
    public func log(forAppID appID: Int, backend: GraphicsBackend = .gptk) -> URL {
        let suffix = backend == .gptk ? "" : "-\(backend.rawValue)"
        return logsDir.appendingPathComponent("\(appID)\(suffix).log")
    }

    /// Launch log for a manual (non-Steam) game, keyed by its stable id.
    public func manualLog(_ id: UUID) -> URL {
        logsDir.appendingPathComponent("manual-\(id.uuidString).log")
    }
}
