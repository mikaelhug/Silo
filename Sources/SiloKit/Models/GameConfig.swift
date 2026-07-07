import Foundation

/// Per-game launch settings, persisted in `config.json`. Keyed by **(appID, backend)**: the same title
/// installed in both the GPTK and DXMT bottles surfaces as two independent library cards that launch in
/// different runtimes, so their launch options + perf flags are separate records — not one shared config.
public struct GameConfig: Codable, Sendable, Hashable, Identifiable {
    /// Composite identity — a title can have one config per graphics backend.
    public var id: String { "\(appID)-\(backend.rawValue)" }
    public let appID: Int
    /// Which bottle/runtime this config is for. GPTK and DXMT copies of one title configure independently.
    public var backend: GraphicsBackend
    public var envFlags: EnvFlags
    public var presence: SteamPresenceStrategy
    /// Game executable relative to the install dir (e.g. `bin/game.exe`). `nil` = auto-detect.
    public var executableRelativePath: String?
    /// Extra arguments appended after the game executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        appID: Int,
        backend: GraphicsBackend = .gptk,
        envFlags: EnvFlags = EnvFlags(),
        presence: SteamPresenceStrategy = .steamAppIDFile,
        executableRelativePath: String? = nil,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.appID = appID
        self.backend = backend
        self.envFlags = envFlags
        self.presence = presence
        self.executableRelativePath = executableRelativePath
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    private enum CodingKeys: String, CodingKey {
        case appID, backend, envFlags, presence, executableRelativePath, customArgs, lastPlayed
    }

    /// Tolerant decode: every field defaults if absent. Critically, a pre-dual-backend `config.json` has no
    /// `backend` key — it decodes as `.gptk`, so existing per-game settings migrate onto the GPTK card
    /// (rather than the whole games array failing to decode and being dropped). Also future-proofs against
    /// new fields, matching `AppState`'s rationale.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        backend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .backend) ?? .gptk
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        presence = try c.decodeIfPresent(SteamPresenceStrategy.self, forKey: .presence) ?? .steamAppIDFile
        executableRelativePath = try c.decodeIfPresent(String.self, forKey: .executableRelativePath)
        customArgs = try c.decodeIfPresent([String].self, forKey: .customArgs) ?? []
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }

    /// Single-field, space-separated view of `customArgs` for a Steam-style "launch options" editor.
    /// Splits on any whitespace and drops empties (quoting is not supported in v1).
    public var launchOptionsString: String {
        get { customArgs.joined(separator: " ") }
        set { customArgs = newValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    }
}
