import Foundation

@MainActor
@Observable
public final class GameSettingsViewModel {
    public var config: GameConfig
    private let configStore: ConfigStore

    public init(config: GameConfig, configStore: ConfigStore) {
        self.config = config
        self.configStore = configStore
    }

    public func save() async {
        _ = try? await configStore.saveGame(config)
    }
}
