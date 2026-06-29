import Foundation

/// Loads/saves the `AppState` document as pretty-printed JSON. Serializes access via an actor.
public actor ConfigStore {
    private let paths: AppPaths
    private let fileManager: FileManager

    public init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// Load the stored state, or a fresh default if nothing is saved / the file is unreadable.
    public func load() -> AppState {
        guard let data = try? Data(contentsOf: paths.configFile),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            return AppState()
        }
        return state
    }

    /// Write the whole state document atomically.
    public func save(_ state: AppState) throws {
        try fileManager.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: paths.configFile, options: .atomic)
    }

    /// Update only the backend config, preserving game configs.
    @discardableResult
    public func saveBackend(_ backend: BackendConfig) throws -> AppState {
        var state = load()
        state.backend = backend
        try save(state)
        return state
    }

    /// Insert/replace a single game config, preserving everything else.
    @discardableResult
    public func saveGame(_ config: GameConfig) throws -> AppState {
        var state = load()
        state.upsert(config)
        try save(state)
        return state
    }

    /// Mutate a single game's config in place (load → mutate → upsert → save), so a field-scoped
    /// update (e.g. `lastPlayed`) can't clobber concurrently-saved fields on the same game config.
    @discardableResult
    public func updateGame(appID: Int, _ mutate: @Sendable (inout GameConfig) -> Void) throws -> AppState {
        var state = load()
        var config = state.config(for: appID)
        mutate(&config)
        state.upsert(config)
        try save(state)
        return state
    }

    /// Remove a single game's config (e.g. on uninstall), preserving everything else.
    @discardableResult
    public func removeGame(appID: Int) throws -> AppState {
        var state = load()
        state.removeGame(appID: appID)
        try save(state)
        return state
    }

    // MARK: - Manual (non-Steam) games

    /// Insert/replace a manual game, preserving everything else.
    @discardableResult
    public func saveManualGame(_ game: ManualGame) throws -> AppState {
        var state = load()
        state.upsertManual(game)
        try save(state)
        return state
    }

    /// Mutate a single manual game in place (load → mutate → upsert → save). No-op if it's gone.
    @discardableResult
    public func updateManualGame(id: UUID, _ mutate: @Sendable (inout ManualGame) -> Void) throws -> AppState {
        var state = load()
        guard var game = state.manualGames.first(where: { $0.id == id }) else { return state }
        mutate(&game)
        state.upsertManual(game)
        try save(state)
        return state
    }

    /// Remove a manual game from the library, preserving everything else.
    @discardableResult
    public func removeManualGame(id: UUID) throws -> AppState {
        var state = load()
        state.removeManual(id: id)
        try save(state)
        return state
    }
}
