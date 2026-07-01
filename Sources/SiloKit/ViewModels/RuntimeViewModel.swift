import Foundation

/// Drives the **Wine** settings tab: installs the latest prebuilt Wine from Silo's CI releases and tracks
/// the default Wine used to launch games.
@MainActor
@Observable
public final class RuntimeViewModel {
    public private(set) var installed: [WineInstall] = []
    public var defaultName: String?
    public var statusMessage: String?
    public private(set) var isInstalling = false

    private let manager: RuntimeManager
    private let repo: String

    /// Called when the default Wine changes so the backend config can adopt its binary.
    public var onDefaultChanged: ((WineInstall) -> Void)?

    public init(manager: RuntimeManager, repo: String, defaultName: String? = nil) {
        self.manager = manager
        self.repo = repo
        self.defaultName = defaultName
    }

    public func refresh() async {
        installed = await manager.installedWines()
        if let name = defaultName, !installed.contains(where: { $0.name == name }) {
            defaultName = nil
        }
    }

    /// Download + install the latest Wine build published to Silo's releases (built by CI from
    /// CrossOver source). Self-contained — also used by the Library onboarding.
    public func installLatest() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            // The Wine repo also hosts the app's own `v*` releases, so pick the newest `wine-*` one.
            let releases = try await manager.availableReleases(repo: repo, limit: 15)
            guard let release = releases.first(where: { $0.tagName.lowercased().hasPrefix("wine") }) else {
                statusMessage = "No Wine build published yet (the CI build-wine workflow must run first)."
                return
            }
            // Already have the latest? Don't re-download the ~250 MB build — just say so (and adopt it as
            // the default if none is set).
            if let existing = installed.first(where: { $0.name == release.tagName }) {
                if defaultName == nil { setDefault(existing) }
                statusMessage = "Latest Wine (\(release.version)) is already installed."
                return
            }
            guard let asset = RuntimeManager.preferredAsset(release) else {
                statusMessage = "Latest Wine release has no installable archive."
                return
            }
            statusMessage = "Downloading \(release.version)… (large file, ~250 MB)"
            // The built-in repo MUST publish a SHA-256 (fail-closed); a user's own override repo may
            // not, so the digest stays best-effort there.
            let requireDigest = repo == Silo.wineRepo
            _ = try await manager.installWine(
                name: release.tagName, from: asset.browserDownloadUrl, requireDigest: requireDigest)
            await refresh()
            if defaultName == nil, let new = installed.first(where: { $0.name == release.tagName }) {
                setDefault(new)
            }
            // A failed de-quarantine/re-sign means Gatekeeper may block this runtime — warn now, at
            // install time, instead of leaving the eventual launch failure unexplained.
            let warning = await manager.lastHardeningIssue
            statusMessage = warning.map { "Installed \(release.version) — ⚠️ \($0)" }
                ?? "Installed \(release.version)."
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
}
