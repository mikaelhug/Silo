import Foundation

@MainActor
@Observable
public final class BackendSettingsViewModel {
    public var config: BackendConfig
    public var statusMessage: String?

    private let configStore: ConfigStore

    /// Called after a successful save so other view models (e.g. the library) can react.
    public var onChange: ((BackendConfig) -> Void)?

    public init(
        config: BackendConfig,
        configStore: ConfigStore
    ) {
        self.config = config
        self.configStore = configStore
    }

    public var isConfigured: Bool { config.isWineConfigured }

    /// Adopt a Wine Manager default as the backend's wine binary and persist.
    public func applyDefaultWine(_ wine: WineInstall) async {
        config.wineBinaryPath = wine.wineBinary
        config.wineRuntimeName = wine.name
        await save()
    }

    /// Adopt a GPTK Manager default as the backend's GPTK lib dir and persist.
    public func applyDefaultGPTK(_ install: GPTKInstall) async {
        config.gptkLibDirPath = install.gptkLibDir
        config.gptkRuntimeName = install.name
        await save()
    }

    public func save() async {
        do {
            try await configStore.saveBackend(config)
            statusMessage = "Saved."
            onChange?(config)
        } catch {
            statusMessage = "Save failed: \((error as NSError).localizedDescription)"
        }
    }
}
