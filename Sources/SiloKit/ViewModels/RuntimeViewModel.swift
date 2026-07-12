import Foundation

/// Everything that differs between the **Wine** and **DXMT** install flows, so ONE `RuntimeViewModel`
/// drives both settings tabs + the onboarding steps (no duplicated download/adopt code). NOT Sendable:
/// it holds MainActor-created closures and is only ever constructed + consumed on the MainActor VM.
@MainActor
public struct RuntimeKind {
    /// Display noun woven into every status string ("Wine" / "DXMT").
    let noun: String
    /// The CI workflow that publishes this runtime, named in the "nothing published yet" message.
    let workflowName: String
    /// Size hint appended to the "Downloading…" status ("(large file, ~250 MB)" / "(~7 MB)").
    let downloadHint: String
    /// Trailing clause for the "set default but the payload is missing" status ("no wine binary was found
    /// in" / "no x86_64-windows module folder was found in") — completed with the install's display name.
    let unusableWarning: String
    /// How many releases to fetch (Wine sits near the top; DXMT tags sit behind wine + app tags).
    let releaseLimit: Int
    /// Pick the release to install from the repo's list (newest-first) — the first `wine-*`, or the DXMT
    /// build matched to the configured wine.
    let pickRelease: ([GitHubRelease]) -> GitHubRelease?
    /// The installed runtimes of this kind (clone-filtered by `RuntimeManager`).
    let installed: () async -> [RuntimeInstall]
    /// Download + install a release's asset, returning the located install.
    let install: (_ name: String, _ url: URL, _ requireDigest: Bool) async throws -> RuntimeInstall
}

public extension RuntimeKind {
    /// The Wine flow: newest `wine-*` release → `installWine`.
    static func wine(manager: RuntimeManager) -> RuntimeKind {
        RuntimeKind(
            noun: "Wine",
            workflowName: "build-wine",
            downloadHint: "(large file, ~250 MB)",
            unusableWarning: "no wine binary was found in",
            releaseLimit: 15,
            pickRelease: { $0.first { $0.tagName.lowercased().hasPrefix("wine") } },
            installed: { await manager.installedWines().map(\.runtimeInstall) },
            install: { name, url, digest in
                try await manager.installWine(name: name, from: url, requireDigest: digest).runtimeInstall
            })
    }

    /// The DXMT flow: the `dxmt-*-cx<ver>` build matched to the configured wine (read live at click time
    /// so the winemetal.so↔wine ABI stays paired) → `installDXMT`.
    static func dxmt(manager: RuntimeManager, wineRuntimeName: @escaping () -> String?) -> RuntimeKind {
        RuntimeKind(
            noun: "DXMT",
            workflowName: "build-dxmt",
            downloadHint: "(~7 MB)",
            unusableWarning: "no x86_64-windows module folder was found in",
            releaseLimit: 30,
            pickRelease: { RuntimeManager.matchedDXMTRelease($0, forWine: wineRuntimeName()) },
            installed: { await manager.installedDXMT().map(\.runtimeInstall) },
            install: { name, url, digest in
                try await manager.installDXMT(name: name, from: url, requireDigest: digest).runtimeInstall
            })
    }
}

/// Drives a runtime settings tab (Wine or DXMT — see `RuntimeKind`): installs the latest prebuilt runtime
/// from Silo's CI releases and tracks the default used to launch games. Shared by the settings tabs AND
/// the Library onboarding steps.
@MainActor
@Observable
public final class RuntimeViewModel {
    public private(set) var installed: [RuntimeInstall] = []
    public var defaultName: String?
    public var statusMessage: String?
    public private(set) var isInstalling = false

    private let kind: RuntimeKind
    private let manager: RuntimeManager
    private let repo: String

    /// Called when the default changes so the backend config can adopt its payload (wine binary / DXMT
    /// lib dir).
    public var onDefaultChanged: ((RuntimeInstall) -> Void)?
    /// Called when the CURRENT default is removed, so the backend config can clear the now-dangling path
    /// (otherwise the readiness gates stay true against a deleted runtime and every launch fails).
    public var onDefaultRemoved: (() -> Void)?

    /// Trailing clause for an unusable install's row warning — surfaced by the shared list section.
    public var unusableWarning: String { kind.unusableWarning }

    public init(kind: RuntimeKind, manager: RuntimeManager, repo: String, defaultName: String? = nil) {
        self.kind = kind
        self.manager = manager
        self.repo = repo
        self.defaultName = defaultName
    }

    /// Convenience: the Wine kind (keeps every existing `RuntimeViewModel(manager:repo:)` call site valid).
    public convenience init(manager: RuntimeManager, repo: String, defaultName: String? = nil) {
        self.init(kind: .wine(manager: manager), manager: manager, repo: repo, defaultName: defaultName)
    }

    public func refresh() async {
        installed = await kind.installed()
        if let name = defaultName, !installed.contains(where: { $0.name == name }) {
            defaultName = nil
        }
    }

    /// Download + install the latest build of this kind published to Silo's releases. Self-contained —
    /// also used by the Library onboarding.
    public func installLatest() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            // The repo also hosts the app's own `v*` releases (and the other runtime kind), so the kind
            // picks its own newest release.
            let releases = try await manager.availableReleases(repo: repo, limit: kind.releaseLimit)
            guard let release = kind.pickRelease(releases) else {
                statusMessage = "No \(kind.noun) build published yet."
                return
            }
            // Already have the latest? Don't re-download — just say so (and adopt it as the default if none
            // is set).
            if let existing = installed.first(where: { $0.name == release.tagName }) {
                if defaultName == nil { setDefault(existing) }
                statusMessage = "Latest \(kind.noun) (\(release.version)) is already installed."
                return
            }
            guard let asset = RuntimeManager.preferredAsset(release) else {
                statusMessage = "Latest \(kind.noun) release has no installable archive."
                return
            }
            statusMessage = "Downloading \(release.version)… \(kind.downloadHint)"
            // The built-in repo MUST publish a SHA-256 (fail-closed); a user's own override repo may not,
            // so the digest stays best-effort there.
            let requireDigest = repo == Silo.wineRepo
            _ = try await kind.install(release.tagName, asset.browserDownloadUrl, requireDigest)
            await refresh()
            if defaultName == nil, let new = installed.first(where: { $0.name == release.tagName }) {
                setDefault(new)
            }
            // A failed de-quarantine means Gatekeeper may block this runtime — warn now, at install time,
            // instead of leaving the eventual launch failure unexplained.
            let warning = await manager.lastHardeningIssue
            statusMessage = warning.map { "Installed \(release.version) — ⚠️ \($0)" }
                ?? "Installed \(release.version)."
        } catch {
            statusMessage = "Install failed: \((error as NSError).localizedDescription)"
        }
    }

    public func remove(_ install: RuntimeInstall) async {
        do {
            try await manager.remove(name: install.name)
            let wasDefault = defaultName == install.name
            if wasDefault { defaultName = nil }
            await refresh()
            if wasDefault { onDefaultRemoved?() }   // clear the dangling path in the persisted config
            statusMessage = "Removed \(install.displayName)."
        } catch {
            statusMessage = "Remove failed: \((error as NSError).localizedDescription)"
        }
    }

    public func setDefault(_ install: RuntimeInstall) {
        defaultName = install.name
        onDefaultChanged?(install)
        statusMessage = install.isUsable ? "Default \(kind.noun): \(install.displayName)."
                                         : "Set default, but \(kind.unusableWarning) \(install.displayName)."
    }

    public func isDefault(_ install: RuntimeInstall) -> Bool { defaultName == install.name }
}
