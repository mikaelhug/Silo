import Foundation

@MainActor
@Observable
public final class RuntimeViewModel {
    public private(set) var installed: [WineRuntime] = []
    public private(set) var available: [GitHubRelease.Asset] = []
    public var repo: String
    public var statusMessage: String?
    public var isBusy = false
    public private(set) var isImportingGPTK = false

    private let manager: RuntimeManager
    private let gptkImporter: GPTKImporter

    /// Called after a successful GPTK import so the backend config can adopt the new lib dir.
    public var onGPTKImported: ((GPTKImporter.Result) -> Void)?

    public init(manager: RuntimeManager, repo: String, gptkImporter: GPTKImporter) {
        self.manager = manager
        self.repo = repo
        self.gptkImporter = gptkImporter
    }

    public func refreshInstalled() async {
        installed = await manager.installedRuntimes()
    }

    public func fetchAvailable() async {
        do {
            available = try await manager.availableAssets(repo: repo)
            statusMessage = available.isEmpty ? "No assets in the latest release." : nil
        } catch {
            statusMessage = "Fetch failed: \((error as NSError).localizedDescription)"
        }
    }

    public func install(_ asset: GitHubRelease.Asset) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await manager.install(name: asset.name, from: asset.browserDownloadUrl)
            await refreshInstalled()
            statusMessage = "Installed \(asset.name)."
        } catch {
            statusMessage = "Install failed: \((error as NSError).localizedDescription)"
        }
    }

    /// Import GPTK from a user-selected Apple `.dmg` (mount → extract `redist/lib`).
    public func importGPTK(from dmgURL: URL) async {
        guard !isImportingGPTK else { return }
        isImportingGPTK = true
        defer { isImportingGPTK = false }
        statusMessage = "Importing GPTK from \(dmgURL.lastPathComponent)…"
        do {
            let result = try await gptkImporter.importGPTK(fromDMG: dmgURL)
            await refreshInstalled()
            onGPTKImported?(result)
            statusMessage = "Imported GPTK. D3DMetal libraries ready and set as the GPTK lib dir."
        } catch {
            statusMessage = "GPTK import failed: \((error as NSError).localizedDescription)"
        }
    }

    public func remove(_ runtime: WineRuntime) async {
        do {
            try await manager.remove(name: runtime.name)
            await refreshInstalled()
        } catch {
            statusMessage = "Remove failed: \((error as NSError).localizedDescription)"
        }
    }
}
