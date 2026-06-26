import Foundation

@MainActor
@Observable
public final class GameSettingsViewModel {
    public var config: GameConfig
    public let appName: String
    private let configStore: ConfigStore

    public init(config: GameConfig, appName: String, configStore: ConfigStore) {
        self.config = config
        self.appName = appName
        self.configStore = configStore
    }

    public func save() async {
        _ = try? await configStore.saveGame(config)
    }
}
