import Foundation

/// Per-game launch settings for a Steam title, persisted in `config.json`, keyed by its Steam `appID`.
public struct GameConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }
    public let appID: Int
    public var envFlags: EnvFlags
    public var presence: SteamPresenceStrategy
    /// Which graphics backend this game runs under — `.auto` (Silo picks per launch) by default.
    public var graphics: GraphicsChoice
    /// Game executable relative to the install dir (e.g. `bin/game.exe`). `nil` = auto-detect.
    public var executableRelativePath: String?
    /// Extra arguments appended after the game executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        appID: Int,
        envFlags: EnvFlags = EnvFlags(),
        presence: SteamPresenceStrategy = .steamAppIDFile,
        graphics: GraphicsChoice = .auto,
        executableRelativePath: String? = nil,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.appID = appID
        self.envFlags = envFlags
        self.presence = presence
        self.graphics = graphics
        self.executableRelativePath = executableRelativePath
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    private enum CodingKeys: String, CodingKey {
        case appID, envFlags, presence, graphics, executableRelativePath, customArgs, lastPlayed
    }

    /// Tolerant decode: every field defaults if absent (the legacy dual-bottle `backend` key is simply
    /// ignored). This future-proofs against new fields, matching `AppState`'s rationale — an old `config.json`
    /// never fails to decode and drop the whole games array.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        presence = try c.decodeIfPresent(SteamPresenceStrategy.self, forKey: .presence) ?? .steamAppIDFile
        graphics = try c.decodeIfPresent(GraphicsChoice.self, forKey: .graphics) ?? .auto
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
