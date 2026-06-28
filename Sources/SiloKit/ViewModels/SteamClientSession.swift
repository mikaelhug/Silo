import Foundation

/// The **single owner of the live bottle Steam client** — the one process that must be up + logged in for
/// games to reach Steamworks (IPC is prefix-scoped). Both the Library (operational: open Steam / launch a
/// game co-resident) and the Steam-bottle settings pane (admin: first sign-in) drive Steam through THIS
/// object, so the client is launched once and tracked in one place. Previously the lifecycle lived in
/// `GameLibraryViewModel` while `SteamBottleViewModel` spawned its own untracked copy — two owners with no
/// shared PID, so settings-launch + a game-launch could start two clients.
@MainActor
@Observable
public final class SteamClientSession {
    private let bottle: SteamBottle
    private let orchestrator: LaunchOrchestrator
    private var wineBinary: URL?

    /// The running client's PID (set only after the launch `await`, so concurrent callers coalesce).
    private var steamPID: Int32?
    private var steamObserver: (any ProcessObservation)?
    /// The in-flight launch, so concurrent callers coalesce onto ONE instead of each starting Steam.
    private var steamLaunch: Task<Void, Never>?
    /// Seconds to wait after a cold start before returning, so a game launched right after can reach Steam
    /// (boot + auto-login + connect). Overridden to 0 in tests.
    var coldStartGraceSeconds: Double = 10
    /// The last launch failure message (for the UI), cleared on a successful launch.
    public private(set) var launchError: String?

    public init(bottle: SteamBottle, orchestrator: LaunchOrchestrator) {
        self.bottle = bottle
        self.orchestrator = orchestrator
    }

    public func updateWine(_ url: URL?) { wineBinary = url }

    /// Bring the bottle's Steam client up (idempotent + coalesced): a no-op if it's already running, joins
    /// an in-flight launch, else launches it (re-applying the steamwebhelper wrapper) and tracks the PID.
    /// Returns whether the client is running after the call. Concurrent callers (two quick Play clicks, or
    /// Play + "Launch Steam") coalesce onto ONE launch via `steamLaunch`.
    @discardableResult
    func ensureRunning() async -> Bool {
        if let pid = steamPID, orchestrator.isRunning(pid: pid) { return true }
        if let inFlight = steamLaunch { await inFlight.value; return steamPID != nil }
        let task = Task { @MainActor in await startSteam() }
        steamLaunch = task
        await task.value
        steamLaunch = nil
        return steamPID != nil
    }

    /// Route a `steam://…` URL to the running client, bringing it up first. Throws if the client can't be
    /// reached (the caller surfaces a status message).
    func sendURL(_ url: String) async throws {
        await ensureRunning()
        try await bottle.sendURL(url, wine: wineBinary)
    }

    private func startSteam() async {
        guard let pid = await launchSteamProcess() else { return }
        steamPID = pid
        launchError = nil
        steamObserver = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in if self?.steamPID == pid { self?.steamPID = nil } }
        }
        if coldStartGraceSeconds > 0 { try? await Task.sleep(for: .seconds(coldStartGraceSeconds)) }
    }

    /// Launch the bottle's Steam client (re-applying the steamwebhelper wrapper first); returns the PID,
    /// or nil after recording `launchError`.
    private func launchSteamProcess() async -> Int32? {
        do {
            if let wine = wineBinary { try bottle.installWebHelperWrapper(wine: wine) }
            return try await bottle.launchSteam(wine: wineBinary)
        } catch {
            launchError = (error as NSError).localizedDescription
            return nil
        }
    }
}
