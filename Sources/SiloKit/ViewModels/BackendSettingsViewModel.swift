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

    /// Adopt the Wine tab's default as the backend's wine binary and persist.
    public func applyDefaultWine(_ install: RuntimeInstall) async {
        config.wineBinaryPath = install.artifact
        config.wineRuntimeName = install.name
        await save()
    }

    /// Adopt the GPTK tab's default as the backend's GPTK lib dir and persist.
    public func applyDefaultGPTK(_ install: GPTKInstall) async {
        config.gptkLibDirPath = install.gptkLibDir
        config.gptkRuntimeName = install.name
        await save()
    }

    /// Adopt a DXMT runtime's module dir as the backend's DXMT lib dir. `name` labels it (the release tag
    /// for a downloaded runtime; the folder name for a manual import).
    public func applyDXMTLibDir(_ dir: URL, name: String? = nil) async {
        config.dxmtLibDirPath = dir
        config.dxmtRuntimeName = name ?? dir.lastPathComponent
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
