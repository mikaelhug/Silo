import Foundation

@MainActor
@Observable
public final class BackendSettingsViewModel {
    public var config: BackendConfig
    public var statusMessage: String?

    private let resolver: BackendResolver
    private let configStore: ConfigStore

    /// Called after a successful save so other view models (e.g. the library) can react.
    public var onChange: ((BackendConfig) -> Void)?

    public init(config: BackendConfig, resolver: BackendResolver, configStore: ConfigStore) {
        self.config = config
        self.resolver = resolver
        self.configStore = configStore
    }

    public var isConfigured: Bool { config.isWineConfigured && config.isMasterBottleConfigured }

    /// Override params are for tests; production calls with defaults.
    public func autodetect(homeDirectory: URL? = nil, applicationsDirectory: URL? = nil) {
        let detected = resolver.autodetect(
            homeDirectory: homeDirectory, applicationsDirectory: applicationsDirectory)
        if detected.detectedSource != .none {
            // Preserve a user-set master bottle if autodetect didn't find one.
            var merged = detected
            if merged.masterBottlePath == nil { merged.masterBottlePath = config.masterBottlePath }
            config = merged
            statusMessage = "Detected \(detected.detectedSource.rawValue)."
        } else {
            statusMessage = "No backend found. Install a runtime or set paths manually."
        }
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
