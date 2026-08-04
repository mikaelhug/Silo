import Foundation

/// Per-game launch settings for a Steam title, persisted in `config.json`, keyed by its Steam `appID`.
public struct GameConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }
    public let appID: Int
    public var envFlags: EnvFlags
    public var presence: SteamPresenceStrategy
    /// Which graphics backend this game runs under — `.auto` (Silo picks per launch) by default.
    public var graphics: GraphicsChoice
    /// A backend Silo LEARNED after Automatic's first pick failed to engage (a reactive GPTK→DXMT reroute).
    /// Kept DISTINCT from `graphics` so the user's `.auto` intent survives — the settings sheet still shows
    /// "Automatic," and `BackendChooser` consults this only for a 64-bit Automatic launch. `nil` = never
    /// learned. Cleared when the user changes `graphics`, or ignored when learned under a different GPTK
    /// runtime (a GPTK upgrade re-probes GPTK — see `learnedUnderRuntime`).
    public var learnedBackend: GraphicsBackend?
    /// The GPTK runtime name (`BackendConfig.gptkRuntimeName`) the hint above was learned under, so a GPTK
    /// upgrade invalidates a stale downgrade and re-tries GPTK. `nil` = learned without version info.
    public var learnedUnderRuntime: String?
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
        learnedBackend: GraphicsBackend? = nil,
        learnedUnderRuntime: String? = nil,
        executableRelativePath: String? = nil,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.appID = appID
        self.envFlags = envFlags
        self.presence = presence
        self.graphics = graphics
        self.learnedBackend = learnedBackend
        self.learnedUnderRuntime = learnedUnderRuntime
        self.executableRelativePath = executableRelativePath
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    private enum CodingKeys: String, CodingKey {
        case appID, envFlags, presence, graphics, learnedBackend, learnedUnderRuntime
        case executableRelativePath, customArgs, lastPlayed
    }

    /// Tolerant decode: every field defaults if absent (the legacy dual-bottle `backend` key is simply
    /// ignored). This future-proofs against new fields, matching `AppState`'s rationale — an old `config.json`
    /// never fails to decode and drop the whole games array.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        envFlags = try c.decodeIfPresent(EnvFlags.self, forKey: .envFlags) ?? EnvFlags()
        presence = try c.decodeIfPresent(SteamPresenceStrategy.self, forKey: .presence) ?? .steamAppIDFile
        // Decoded as RAW STRINGS, not as the enums. A strict decode of an unknown case THROWS, and that
        // throw propagates all the way out of `AppState` — `ConfigStore.load()` then falls back to the .bak
        // (which has the same value), fails again, and returns a FRESH AppState: every runtime path, every
        // per-game setting and every manual game silently gone, with the next save overwriting the file.
        // That makes adding any future backend a one-way door — roll back one version and the user is wiped.
        // `ManualGame.graphics` and `EnvFlags.metalBackend` already take this precaution; these did not.
        graphics = (try c.decodeIfPresent(String.self, forKey: .graphics))
            .flatMap(GraphicsChoice.init(rawValue:)) ?? .auto
        learnedBackend = (try c.decodeIfPresent(String.self, forKey: .learnedBackend))
            .flatMap(GraphicsBackend.init(rawValue:))
        learnedUnderRuntime = try c.decodeIfPresent(String.self, forKey: .learnedUnderRuntime)
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
