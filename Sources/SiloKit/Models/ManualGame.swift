import Foundation

/// A non-Steam game the user added by hand: an absolute path to a Windows `.exe` on disk, launched in its
/// OWN isolated Wine bottle (`ManualBottles/<id>`). Unlike `SteamApp` — which is *discovered* from the
/// bottle's `appmanifest_*.acf` — a `ManualGame` is user-authored and persisted in `config.json`.
public struct ManualGame: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The bottle this game runs in (`ManualBottles/<bottleID>`). Defaults to `id`, so a portable-`.exe`
    /// game — and every pre-existing config — owns its bottle 1:1. When several games come from ONE
    /// installer, they carry the SAME `bottleID` so they share that install's prefix: N Start-Menu shortcuts
    /// become N library entries in one bottle, not N re-installs. Bottle deletion is therefore ref-counted.
    public var bottleID: UUID
    public var name: String
    /// Absolute host path to the game executable — typically inside the bottle's `drive_c` after running
    /// the game's installer, or a portable `.exe` anywhere readable. Wine launches host paths directly.
    public var executablePath: URL
    /// The "start in" directory the target expects, when it differs from the exe's own folder (e.g. an
    /// installer shortcut whose target resolves data relative to a parent dir). `nil` → default to the exe's
    /// folder. Sourced from a shortcut's `WORKING_DIR` at add time.
    public var workingDirectory: URL?
    /// Per-game performance + environment tuning (same knobs as a Steam game). Defaults are the
    /// Apple-Silicon GPTK baseline.
    public var envFlags: EnvFlags
    /// The graphics-backend **choice** for this game — `.auto` (Silo picks per launch via `BackendChooser`:
    /// 32-bit → DXMT, else GPTK), or an explicit `.gptk` / `.dxmt` pin — exactly like a Steam game's
    /// `GameConfig.graphics`. Manual games each get their own isolated bottle, so the resolved backend just
    /// overlays that bottle's runtime. Defaults to `.auto`.
    public var graphics: GraphicsChoice
    /// Extra arguments appended after the executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        id: UUID = UUID(),
        bottleID: UUID? = nil,
        name: String,
        executablePath: URL,
        workingDirectory: URL? = nil,
        envFlags: EnvFlags = EnvFlags(),
        graphics: GraphicsChoice = .auto,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.id = id
        self.bottleID = bottleID ?? id
        self.name = name
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.envFlags = envFlags
        self.graphics = graphics
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    /// Single-field, space-separated view of `customArgs` for a Steam-style launch-options editor
    /// (splits on whitespace, drops empties; quoting unsupported, matching `GameConfig`).
    public var launchOptionsString: String {
        get { customArgs.joined(separator: " ") }
        set { customArgs = newValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    /// The `GameConfig` used to launch this manual game: appID 0 (not a Steam title), no Steam presence,
    /// and the game's own env flags + args. The single place a `ManualGame` maps to a launch config
    /// (consumed by `LaunchOrchestrator.launchManualGame`).
    public var gameConfig: GameConfig {
        GameConfig(appID: 0, envFlags: envFlags, presence: .none, customArgs: customArgs)
    }

    // MARK: - Codable (tolerant: migrates the pre-Automatic `backend` field; never throws on a missing one)

    private enum CodingKeys: String, CodingKey {
        // `backend` is read-only legacy — decoded for migration, never encoded (new configs write `graphics`).
        case id, bottleID, name, executablePath, workingDirectory, envFlags, graphics, backend, customArgs,
             lastPlayed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // A config predating shared bottles has no `bottleID` → the game owns its own bottle (bottleID == id).
        bottleID = try c.decodeIfPresent(UUID.self, forKey: .bottleID) ?? id
        name = try c.decode(String.self, forKey: .name)
        executablePath = try c.decode(URL.self, forKey: .executablePath)
        workingDirectory = try c.decodeIfPresent(URL.self, forKey: .workingDirectory)
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        // `graphics` (a GraphicsChoice, incl. Automatic) supersedes the pre-Automatic `backend` (a concrete
        // GraphicsBackend). Decode both as raw strings so an unknown/newer value (e.g. a config written by a
        // future Silo) degrades to Automatic rather than THROWING — a throw here drops the ENTIRE config
        // document on load (backend + every game config), not just this game (see AppState's tolerant decode).
        // Migrate an old explicit backend to the matching explicit choice; neither key (a very old config) →
        // Automatic.
        if let raw = try c.decodeIfPresent(String.self, forKey: .graphics) {
            graphics = GraphicsChoice(rawValue: raw) ?? .auto
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .backend) {
            graphics = legacy == GraphicsBackend.dxmt.rawValue ? .dxmt : .gptk
        } else {
            graphics = .auto
        }
        customArgs = try c.decodeIfPresent([String].self, forKey: .customArgs) ?? []
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(bottleID, forKey: .bottleID)
        try c.encode(name, forKey: .name)
        try c.encode(executablePath, forKey: .executablePath)
        try c.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try c.encode(envFlags, forKey: .envFlags)
        try c.encode(graphics, forKey: .graphics)
        try c.encode(customArgs, forKey: .customArgs)
        try c.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
    }
}
