import Foundation

@MainActor
@Observable
public final class GameSettingsViewModel {
    public var config: GameConfig
    /// Set when a save fails (config.json unwritable) — the sheet stays open and shows it.
    public private(set) var errorMessage: String?
    private let configStore: ConfigStore

    public init(config: GameConfig, configStore: ConfigStore) {
        self.config = config
        self.configStore = configStore
    }

    /// Persist the edited config. Returns whether it saved — callers only dismiss on success.
    @discardableResult
    public func save() async -> Bool {
        do {
            _ = try await configStore.saveGame(config)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't save: \((error as NSError).localizedDescription)"
            return false
        }
    }
}
