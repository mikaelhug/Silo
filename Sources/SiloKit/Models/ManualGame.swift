import Foundation

/// A non-Steam game the user added by hand: an absolute path to a Windows `.exe` on disk, launched in its
/// OWN isolated Wine bottle (`ManualBottles/<id>`). Unlike `SteamApp` — which is *discovered* from the
/// bottle's `appmanifest_*.acf` — a `ManualGame` is user-authored and persisted in `config.json`.
public struct ManualGame: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// Absolute host path to the game executable — typically inside the bottle's `drive_c` after running
    /// the game's installer, or a portable `.exe` anywhere readable. Wine launches host paths directly.
    public var executablePath: URL
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
        name: String,
        executablePath: URL,
        envFlags: EnvFlags = EnvFlags(),
        graphics: GraphicsChoice = .auto,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
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
    /// and the game's own env flags + args. The single place a `ManualGame` maps to a launch config —
    /// shared by the launch path and the Desktop-shortcut builder.
    public var gameConfig: GameConfig {
        GameConfig(appID: 0, envFlags: envFlags, presence: .none, customArgs: customArgs)
    }

    // MARK: - Codable (tolerant: migrates the pre-Automatic `backend` field; never throws on a missing one)

    private enum CodingKeys: String, CodingKey {
        // `backend` is read-only legacy — decoded for migration, never encoded (new configs write `graphics`).
        case id, name, executablePath, envFlags, graphics, backend, customArgs, lastPlayed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executablePath = try c.decode(URL.self, forKey: .executablePath)
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        // `graphics` (a GraphicsChoice, incl. Automatic) supersedes the pre-Automatic `backend` (a concrete
        // GraphicsBackend). Migrate an old explicit backend to the matching explicit choice; a config with
        // neither field (very old) defaults to Automatic. Never throw — that would drop the whole
        // manualGames array on load (see AppState's tolerant decode).
        if let choice = try c.decodeIfPresent(GraphicsChoice.self, forKey: .graphics) {
            graphics = choice
        } else if let legacy = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backend) {
            graphics = legacy == .dxmt ? .dxmt : .gptk
        } else {
            graphics = .auto
        }
        customArgs = try c.decodeIfPresent([String].self, forKey: .customArgs) ?? []
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(executablePath, forKey: .executablePath)
        try c.encode(envFlags, forKey: .envFlags)
        try c.encode(graphics, forKey: .graphics)
        try c.encode(customArgs, forKey: .customArgs)
        try c.encodeIfPresent(lastPlayed, forKey: .lastPlayed)
    }
}
