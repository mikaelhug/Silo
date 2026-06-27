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

    /// Remove a single game's config (e.g. on uninstall), preserving everything else.
    @discardableResult
    public func removeGame(appID: Int) throws -> AppState {
        var state = load()
        state.removeGame(appID: appID)
        try save(state)
        return state
    }
}
