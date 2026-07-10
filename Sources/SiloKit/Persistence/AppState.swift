import Foundation

/// The persisted application document: global backend config + per-game settings + manual (non-Steam) games.
public struct AppState: Codable, Sendable, Hashable {
    public var backend: BackendConfig
    public var games: [GameConfig]
    /// Non-Steam games the user added by hand (Steam games are discovered, not stored).
    public var manualGames: [ManualGame]

    public init(
        backend: BackendConfig = BackendConfig(),
        games: [GameConfig] = [],
        manualGames: [ManualGame] = []
    ) {
        self.backend = backend
        self.games = games
        self.manualGames = manualGames
    }

    private enum CodingKeys: String, CodingKey { case backend, games, manualGames }

    /// Tolerant decode: every field defaults if absent, so adding a new field never makes an OLD
    /// `config.json` undecodable — which matters because `ConfigStore.load` discards the entire document
    /// (losing the user's backend + game configs) if decoding throws.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decodeIfPresent(BackendConfig.self, forKey: .backend) ?? BackendConfig()
        games = try c.decodeIfPresent([GameConfig].self, forKey: .games) ?? []
        manualGames = try c.decodeIfPresent([ManualGame].self, forKey: .manualGames) ?? []
    }

    /// Existing config for a title, or a fresh default if none is stored yet. Keyed by `appID`.
    public func config(for appID: Int) -> GameConfig {
        games.first { $0.appID == appID } ?? GameConfig(appID: appID)
    }

    /// Insert or replace a game's config (matched by `appID`).
    public mutating func upsert(_ config: GameConfig) {
        if let index = games.firstIndex(where: { $0.appID == config.appID }) {
            games[index] = config
        } else {
            games.append(config)
        }
    }

    /// Drop a title's config (e.g. on uninstall).
    public mutating func removeGame(appID: Int) {
        games.removeAll { $0.appID == appID }
    }

    // MARK: - Manual (non-Steam) games

    /// Insert or replace a manual game (matched by `id`).
    public mutating func upsertManual(_ game: ManualGame) {
        if let index = manualGames.firstIndex(where: { $0.id == game.id }) {
            manualGames[index] = game
        } else {
            manualGames.append(game)
        }
    }

    /// Remove a manual game from the library.
    public mutating func removeManual(id: UUID) {
        manualGames.removeAll { $0.id == id }
    }
}
