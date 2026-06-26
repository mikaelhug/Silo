import Foundation

@MainActor
@Observable
public final class BackendSettingsViewModel {
    public var config: BackendConfig
    public var statusMessage: String?
    public private(set) var isInstallingBottle = false

    private let resolver: BackendResolver
    private let configStore: ConfigStore
    private let steamInstaller: SteamBottleInstaller
    private let paths: AppPaths

    /// Called after a successful save so other view models (e.g. the library) can react.
    public var onChange: ((BackendConfig) -> Void)?

    public init(
        config: BackendConfig,
        resolver: BackendResolver,
        configStore: ConfigStore,
        steamInstaller: SteamBottleInstaller,
        paths: AppPaths
    ) {
        self.config = config
        self.resolver = resolver
        self.configStore = configStore
        self.steamInstaller = steamInstaller
        self.paths = paths
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

    /// One-click: boot the Master Steam bottle and silently install the Steam client.
    public func installSteamBottle() async {
        guard !isInstallingBottle else { return }
        guard config.steamWine != nil else {
            statusMessage = "Set a Wine binary first (install a runtime or auto-detect)."
            return
        }
        isInstallingBottle = true
        defer { isInstallingBottle = false }
        statusMessage = "Setting up Master Steam bottle (boot → download → install)…"
        let bottle = config.masterBottlePath ?? paths.masterBottleDefault
        do {
            _ = try await steamInstaller.install(bottle: bottle, wine: config.steamWine)
            config.masterBottlePath = bottle
            await save()
            statusMessage = "Master Steam bottle ready. Open Steam, log in, and download games."
        } catch {
            statusMessage = "Steam bottle setup failed: \((error as NSError).localizedDescription)"
        }
    }
}
