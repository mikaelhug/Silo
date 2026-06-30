import Foundation

/// A non-Steam game the user added by hand: an absolute path to a Windows `.exe` on disk, launched in its
/// OWN isolated Wine bottle (`ManualBottles/<id>`) under GPTK (no Steamworks needed). Unlike `SteamApp` —
/// which is *discovered* from the bottle's `appmanifest_*.acf` — a `ManualGame` is user-authored and
/// persisted in `config.json`.
public struct ManualGame: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// Absolute host path to the game executable — typically inside the bottle's `drive_c` after running
    /// the game's installer, or a portable `.exe` anywhere readable. Wine launches host paths directly.
    public var executablePath: URL
    /// Per-game performance + environment tuning (same knobs as a Steam game). Defaults are the
    /// Apple-Silicon GPTK baseline.
    public var envFlags: EnvFlags
    /// The graphics translation layer this game runs under. Manual games each get their own isolated
    /// bottle, so the backend is a free per-game choice (unlike Steam games, whose backend = their bottle).
    /// Defaults to `.gptk`; the isolated bottle's runtime is overlaid for whichever backend is selected.
    public var backend: GraphicsBackend
    /// Extra arguments appended after the executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        executablePath: URL,
        envFlags: EnvFlags = EnvFlags(),
        backend: GraphicsBackend = .gptk,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.envFlags = envFlags
        self.backend = backend
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    /// Single-field, space-separated view of `customArgs` for a Steam-style launch-options editor
    /// (splits on whitespace, drops empties; quoting unsupported, matching `GameConfig`).
    public var launchOptionsString: String {
        get { customArgs.joined(separator: " ") }
        set { customArgs = newValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    }

    // MARK: - Codable (tolerates a missing `backend` so old config.json keeps its manual games)

    private enum CodingKeys: String, CodingKey {
        case id, name, executablePath, envFlags, backend, customArgs, lastPlayed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executablePath = try c.decode(URL.self, forKey: .executablePath)
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        // New field: a config written before DXMT support has no `backend` → default to GPTK (don't
        // throw, which would drop the whole manualGames array on load — see AppState's tolerant decode).
        backend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backend) ?? .gptk
        customArgs = try c.decodeIfPresent([String].self, forKey: .customArgs) ?? []
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }
}
