import Foundation

@MainActor
@Observable
public final class RuntimeViewModel {
    public private(set) var installed: [WineRuntime] = []
    public private(set) var available: [GitHubRelease.Asset] = []
    public var repo: String
    public var statusMessage: String?
    public var isBusy = false

    private let manager: RuntimeManager

    public init(manager: RuntimeManager, repo: String) {
        self.manager = manager
        self.repo = repo
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

    public func remove(_ runtime: WineRuntime) async {
        do {
            try await manager.remove(name: runtime.name)
            await refreshInstalled()
        } catch {
            statusMessage = "Remove failed: \((error as NSError).localizedDescription)"
        }
    }
}
