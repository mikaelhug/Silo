import Foundation

/// Per-game launch settings, persisted in `config.json`.
public struct GameConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { appID }
    public let appID: Int
    public var backend: GraphicsBackend
    public var envFlags: EnvFlags
    public var presence: SteamPresenceStrategy
    /// User-provided Steam-API emulator stub (only used when `presence == .emulatorStub`).
    public var steamStubSourcePath: URL?
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
        steamStubSourcePath: URL? = nil,
        executableRelativePath: String? = nil,
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.appID = appID
        self.backend = backend
        self.envFlags = envFlags
        self.presence = presence
        self.steamStubSourcePath = steamStubSourcePath
        self.executableRelativePath = executableRelativePath
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }
}
