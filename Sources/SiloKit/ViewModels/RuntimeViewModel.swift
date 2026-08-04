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

    /// The DXVK flow: the `dxvk-*-cx<ver>` build matched to the configured wine (a soft preference — DXVK is
    /// native and wine-independent) → `installDXVK`.
    static func dxvk(manager: RuntimeManager, wineRuntimeName: @escaping () -> String?) -> RuntimeKind {
        RuntimeKind(
            noun: "DXVK",
            workflowName: "build-dxvk",
            downloadHint: "(~15 MB)",
            // DXVK is identified by its bundled Vulkan driver, so THAT is what's missing when a tree is
            // unusable — saying "no x86_64-windows module folder" would point at a folder that IS present.
            unusableWarning: "no bundled Vulkan driver was found in",
            releaseLimit: 30,
            pickRelease: { RuntimeManager.matchedDXVKRelease($0, forWine: wineRuntimeName()) },
            installed: { await manager.installedDXVK().map(\.runtimeInstall) },
            install: { name, url, digest in
                try await manager.installDXVK(name: name, from: url, requireDigest: digest).runtimeInstall
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
    /// Refuses a destructive runtime change while something is live in a bottle, returning the message to
    /// show. Silo launches games and the Steam client DETACHED and never owns their lifecycle, so removing
    /// (or reinstalling, which deletes before it publishes) a runtime would pull the wine tree out from
    /// under a running wineserver. Bottle relocation and self-update already gate on this; runtime changes
    /// did not. Nil (the default) means "no guard wired" — used in tests.
    public var blockedReason: (() -> String?)?

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

    /// How many pages of releases to walk looking for this kind's newest build (see `installLatest`).
    /// `releaseLimit` per page, so 5 pages covers 75–150 releases — far beyond any realistic backlog.
    private static let maxReleasePages = 5

    public func refresh() async {
        installed = await kind.installed()
        if let name = defaultName, !installed.contains(where: { $0.name == name }) {
            // The default's runtime is GONE (deleted outside the app, a restore that copied only config.json,
            // or a crash mid-install). Clearing `defaultName` alone left the PERSISTED path dangling, so the
            // readiness gates — plain `!= nil` checks — stayed green: onboarding showed "Done", runFullSetup
            // skipped the install, and every launch failed against a path that isn't there while this tab said
            // "None installed". Tell the owner so the config is cleared and setup re-surfaces the step.
            defaultName = nil
            onDefaultRemoved?()
        }
    }

    /// Download + install the latest build of this kind published to Silo's releases. Self-contained —
    /// also used by the Library onboarding.
    public func installLatest() async {
        guard !isInstalling else { return }
        // Reinstalling replaces the tree in place, so it is as destructive as a removal while a game runs.
        if let reason = blockedReason?() { statusMessage = reason; return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            // The repo also hosts the app's own `v*` releases (and the other runtime kinds), so the kind picks
            // its own newest release — and we PAGE until we find it. A single page silently broke as soon as
            // enough app releases stacked above the newest runtime tag (it sinks with every app release), so
            // onboarding would have started failing with "No <kind> build published yet." on a repo that had
            // the runtime published all along.
            var release: GitHubRelease?
            for page in 1...Self.maxReleasePages {
                // Page 1 failing is a real "can't reach GitHub" and propagates. A LATER page failing is not
                // worth discarding the search over — stop and use what we have, rather than turning a blip on
                // page 3 into an install failure.
                let batch: [GitHubRelease]
                if page == 1 {
                    batch = try await manager.availableReleases(repo: repo, limit: kind.releaseLimit, page: 1)
                } else if let more = try? await manager.availableReleases(
                    repo: repo, limit: kind.releaseLimit, page: page) {
                    batch = more
                } else { break }
                if batch.isEmpty { break }                    // ran off the end of the release list
                if let found = kind.pickRelease(batch) { release = found; break }
            }
            guard let release else {
                statusMessage = "No \(kind.noun) build published yet."
                return
            }
            // Already have the latest? Don't re-download — just say so (and adopt it as the default if none
            // is set).
            if let existing = installed.first(where: { $0.name == release.tagName }), existing.isUsable {
                if defaultName == nil { setDefault(existing) }
                statusMessage = "Latest \(kind.noun) (\(release.version)) is already installed."
                return
            }
            // An install of the right NAME but missing its payload (e.g. a DXVK tree with no Vulkan driver)
            // must NOT short-circuit: `onDefaultChanged` refuses to adopt it, so the readiness gate would
            // stay false while this reported "already installed" on every retry — a permanent dead end.
            // Fall through and re-download it instead.
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
            statusMessage = "Couldn't install: \((error as NSError).localizedDescription)"
        }
    }

    public func remove(_ install: RuntimeInstall) async {
        if let reason = blockedReason?() { statusMessage = reason; return }
        do {
            try await manager.remove(name: install.name)
            let wasDefault = defaultName == install.name
            if wasDefault { defaultName = nil }
            await refresh()
            if wasDefault { onDefaultRemoved?() }   // clear the dangling path in the persisted config
            statusMessage = "Removed \(install.displayName)."
        } catch {
            statusMessage = "Couldn't remove: \((error as NSError).localizedDescription)"
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
