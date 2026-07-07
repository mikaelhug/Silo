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

    /// Existing config for a title in a given bottle, or a fresh default (carrying that backend) if none is
    /// stored yet. Keyed by (appID, backend) so the GPTK and DXMT cards of one title stay independent.
    public func config(for appID: Int, backend: GraphicsBackend = .gptk) -> GameConfig {
        games.first { $0.appID == appID && $0.backend == backend } ?? GameConfig(appID: appID, backend: backend)
    }

    /// Insert or replace a game's config (matched by its (appID, backend) identity).
    public mutating func upsert(_ config: GameConfig) {
        if let index = games.firstIndex(where: { $0.appID == config.appID && $0.backend == config.backend }) {
            games[index] = config
        } else {
            games.append(config)
        }
    }

    /// Drop a title's config for one backend (e.g. on uninstall from that bottle), leaving the other
    /// bottle's copy untouched.
    public mutating func removeGame(appID: Int, backend: GraphicsBackend = .gptk) {
        games.removeAll { $0.appID == appID && $0.backend == backend }
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
