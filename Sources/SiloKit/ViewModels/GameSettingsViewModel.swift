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
        // Snapshot the user-editable fields (all Sendable) before the @Sendable mutation closure.
        let appID = config.appID
        let (envFlags, presence, graphics) = (config.envFlags, config.presence, config.graphics)
        let (exePath, args) = (config.executableRelativePath, config.customArgs)
        do {
            // Field-merge into the CURRENT record rather than upserting the whole snapshot captured when the
            // sheet opened — otherwise a `lastPlayed` written by launching the same game while the sheet is
            // open (via `updateGame`) is reverted on save. Only the user-editable fields are applied.
            _ = try await configStore.updateGame(appID: appID) {
                $0.envFlags = envFlags
                $0.presence = presence
                $0.graphics = graphics
                $0.executableRelativePath = exePath
                $0.customArgs = args
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn't save: \((error as NSError).localizedDescription)"
            return false
        }
    }
}
