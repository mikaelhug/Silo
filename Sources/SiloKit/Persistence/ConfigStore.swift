import Foundation

/// Loads/saves the `AppState` document as pretty-printed JSON. Serializes access via an actor.
public actor ConfigStore {
    private let paths: AppPaths
    private let fileManager: FileManager

    public init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    /// The recovery copy written on every save; `load()` falls back to it when the primary is corrupt.
    private var backupFile: URL { paths.configFile.appendingPathExtension("bak") }

    /// Load the stored state, or a fresh default if nothing is saved / the file is unreadable.
    /// A present-but-undecodable `config.json` (torn write, disk corruption) restores the `.bak` from the
    /// last good save — instead of silently wiping every game/backend setting — and self-heals the primary.
    /// A *missing* primary still loads a fresh default: deleting `config.json` stays a deliberate reset.
    public func load() -> AppState {
        if let data = try? Data(contentsOf: paths.configFile),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            return state
        }
        guard fileManager.fileExists(atPath: paths.configFile.path),
              let backup = try? Data(contentsOf: backupFile),
              let restored = try? JSONDecoder().decode(AppState.self, from: backup) else {
            return AppState()
        }
        try? backup.write(to: paths.configFile, options: .atomic)   // self-heal, best-effort
        return restored
    }

    /// Write the whole state document atomically, then refresh the `.bak` recovery copy.
    public func save(_ state: AppState) throws {
        try fileManager.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: paths.configFile, options: .atomic)
        // Best-effort: a failed backup must not fail the save that just succeeded.
        try? data.write(to: backupFile, options: .atomic)
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
    public func updateGame(
        appID: Int, backend: GraphicsBackend = .gptk, _ mutate: @Sendable (inout GameConfig) -> Void
    ) throws -> AppState {
        var state = load()
        var config = state.config(for: appID, backend: backend)
        mutate(&config)
        state.upsert(config)
        try save(state)
        return state
    }

    /// Remove a single title's config for one backend (e.g. on uninstall from that bottle), preserving
    /// everything else — including the other bottle's copy of the same title.
    @discardableResult
    public func removeGame(appID: Int, backend: GraphicsBackend = .gptk) throws -> AppState {
        var state = load()
        state.removeGame(appID: appID, backend: backend)
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
