import Foundation

@MainActor
@Observable
public final class BackendSettingsViewModel {
    public var config: BackendConfig
    public var statusMessage: String?

    private let resolver: BackendResolver
    private let configStore: ConfigStore
    private let paths: AppPaths

    /// Called after a successful save so other view models (e.g. the library) can react.
    public var onChange: ((BackendConfig) -> Void)?

    public init(
        config: BackendConfig,
        resolver: BackendResolver,
        configStore: ConfigStore,
        paths: AppPaths
    ) {
        self.config = config
        self.resolver = resolver
        self.configStore = configStore
        self.paths = paths
    }

    public var isConfigured: Bool { config.isWineConfigured }

    /// Override params are for tests; production calls with defaults.
    public func autodetect(homeDirectory: URL? = nil, applicationsDirectory: URL? = nil) {
        let detected = resolver.autodetect(
            homeDirectory: homeDirectory, applicationsDirectory: applicationsDirectory)
        if detected.detectedSource != .none {
            // Autodetect only discovers *runtime* paths — never the Steam sign-in or a user-set master
            // bottle. Carry those over so re-detecting a runtime doesn't sign the user out (the bug where
            // the logged-in account "fell away" from the UI) or forget their bottle.
            var merged = detected
            if merged.masterBottlePath == nil { merged.masterBottlePath = config.masterBottlePath }
            merged.steamUsername = merged.steamUsername ?? config.steamUsername
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
