import Foundation

/// Drives the Wine tab of the Wine Manager: lists the latest prebuilt Wine releases (Heroic-style),
/// installs them one-click, and tracks the default Wine used to launch games.
@MainActor
@Observable
public final class RuntimeViewModel {
    public private(set) var latest: [GitHubRelease] = []
    public private(set) var installed: [WineInstall] = []
    public var defaultName: String?
    public var statusMessage: String?
    public private(set) var busyTag: String?     // tag currently installing

    private let manager: RuntimeManager
    private let repo: String

    /// Called when the default Wine changes so the backend config can adopt its binary.
    public var onDefaultChanged: ((WineInstall) -> Void)?

    public init(manager: RuntimeManager, repo: String, defaultName: String? = nil) {
        self.manager = manager
        self.repo = repo
        self.defaultName = defaultName
    }

    public var isInstalling: Bool { busyTag != nil }

    public func refresh() async {
        installed = await manager.installedWines()
        if let name = defaultName, !installed.contains(where: { $0.name == name }) {
            defaultName = nil
        }
    }

    /// Fetch the latest few Wine releases to offer for install.
    public func fetchLatest() async {
        do {
            latest = try await manager.availableReleases(repo: repo, limit: 3)
            if latest.isEmpty { statusMessage = "No Wine releases found." }
        } catch {
            statusMessage = "Couldn't fetch Wine versions: \((error as NSError).localizedDescription)"
        }
    }

    /// Onboarding helper: fetch (if needed) and install the newest Wine release.
    public func installLatest() async {
        if latest.isEmpty { await fetchLatest() }
        guard let newest = latest.first else { return }
        await install(newest)
    }

    public func install(_ release: GitHubRelease) async {
        guard busyTag == nil else { return }
        guard let asset = RuntimeManager.preferredAsset(release) else {
            statusMessage = "No installable archive in \(release.tagName)."
            return
        }
        busyTag = release.tagName
        defer { busyTag = nil }
        statusMessage = "Downloading \(release.version)… (this is a large file)"
        do {
            _ = try await manager.installWine(name: release.tagName, from: asset.browserDownloadUrl)
            await refresh()
            if defaultName == nil, let new = installed.first(where: { $0.name == release.tagName }) {
                setDefault(new)
            }
            statusMessage = "Installed \(release.version)."
        } catch {
            statusMessage = "Install failed: \((error as NSError).localizedDescription)"
        }
    }

    public func remove(_ wine: WineInstall) async {
        do {
            try await manager.remove(name: wine.name)
            if defaultName == wine.name { defaultName = nil }
            await refresh()
            statusMessage = "Removed \(wine.displayName)."
        } catch {
            statusMessage = "Remove failed: \((error as NSError).localizedDescription)"
        }
    }

    public func setDefault(_ wine: WineInstall) {
        defaultName = wine.name
        onDefaultChanged?(wine)
        statusMessage = wine.isUsable ? "Default Wine: \(wine.displayName)."
                                      : "Set default, but no wine binary was found in \(wine.displayName)."
    }

    public func isDefault(_ wine: WineInstall) -> Bool { defaultName == wine.name }
    public func isInstalled(_ release: GitHubRelease) -> Bool {
        installed.contains { $0.name == release.tagName }
    }
}
