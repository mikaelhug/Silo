import Foundation

/// The persisted application document: global backend config + per-game settings.
public struct AppState: Codable, Sendable, Hashable {
    public var backend: BackendConfig
    public var games: [GameConfig]

    public init(backend: BackendConfig = BackendConfig(), games: [GameConfig] = []) {
        self.backend = backend
        self.games = games
    }

    /// Existing config for an app, or a fresh default if none is stored yet.
    public func config(for appID: Int) -> GameConfig {
        games.first { $0.appID == appID } ?? GameConfig(appID: appID)
    }

    /// Insert or replace a game's config.
    public mutating func upsert(_ config: GameConfig) {
        if let index = games.firstIndex(where: { $0.appID == config.appID }) {
            games[index] = config
        } else {
            games.append(config)
        }
    }
}
