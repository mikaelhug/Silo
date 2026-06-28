import Foundation

/// Per-game launch settings, persisted in `config.json`.
public struct GameConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }
    public let appID: Int
    public var envFlags: EnvFlags
    public var presence: SteamPresenceStrategy
    /// Game executable relative to the install dir (e.g. `bin/game.exe`). `nil` = auto-detect.
    public var executableRelativePath: String?
    /// Extra arguments appended after the game executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        appID: Int,
        envFlags: EnvFlags = EnvFlags(),
        presence: SteamPresenceStrategy = .steamAppIDFile,
        executableRelativePath: String? = nil,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.appID = appID
        self.envFlags = envFlags
        self.presence = presence
        self.executableRelativePath = executableRelativePath
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    /// Single-field, space-separated view of `customArgs` for a Steam-style "launch options" editor.
    /// Splits on any whitespace and drops empties (quoting is not supported in v1).
    public var launchOptionsString: String {
        get { customArgs.joined(separator: " ") }
        set { customArgs = newValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    }
}
