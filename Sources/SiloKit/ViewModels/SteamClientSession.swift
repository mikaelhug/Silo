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
    /// Last-resort failsafe (seconds) for the readiness wait so a missing signal can't hang a launch — NOT
    /// a fixed wait: a cold start resolves the instant Steam registers its `ActiveProcess` (event-driven,
    /// see `awaitSteamReady`). 0 disables the wait entirely (tests).
    var readinessTimeout: Double = 20
    /// The last launch failure message (for the UI), cleared on a successful launch.
    public private(set) var launchError: String?

    public init(bottle: SteamBottle, orchestrator: LaunchOrchestrator) {
        self.bottle = bottle
        self.orchestrator = orchestrator
    }

    /// Defensive teardown: the live VMs are process-lifetime singletons, so this normally never fires, but
    /// it ensures the exit observation + any in-flight launch don't outlive the session if that ever changes.
    /// `isolated` so it can touch the `@MainActor` state it's cleaning up.
    isolated deinit { steamObserver?.cancel(); steamLaunch?.cancel() }

    public func updateWine(_ url: URL?) { wineBinary = url }

    /// Which backend bottle this session's Steam client belongs to (GPTK or DXMT).
    public var backend: GraphicsBackend { bottle.backend }

    /// Whether the bottle's Steam client is live right now (its tracked PID is still alive).
    public var isRunning: Bool {
        guard let pid = steamPID else { return false }
        return orchestrator.isRunning(pid: pid)
    }

    /// Stop this bottle's Steam client (best-effort). Used to keep only ONE client online at a time across
    /// the two Steam bottles — the same Steam account can't be "in-game" on two clients at once.
    public func stop() {
        guard let pid = steamPID else { return }
        orchestrator.terminate(pid: pid)
        steamPID = nil
        steamObserver?.cancel(); steamObserver = nil
    }

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
        // Safe to clear unconditionally: while `steamLaunch` is non-nil every other caller joins it via the
        // `if let inFlight` branch above instead of starting a new launch, so no newer launch can have
        // replaced this slot by the time we resume here.
        steamLaunch = nil
        return steamPID != nil
    }

    /// Route a `steam://…` URL to the running client, bringing it up first. Throws if the client can't be
    /// reached (the caller surfaces a status message).
    func sendURL(_ url: String) async throws {
        await ensureRunning()
        try await bottle.sendURL(url, wine: wineBinary)
    }

    // MARK: - Warm-up (fold Steam's first-run self-update into setup)

    /// Phases of the one-time warm-up, surfaced to the UI so the user knows what the wait is. `downloading`
    /// carries a 0…1 fraction when known (parsed from Steam's own progress log) for a real progress bar.
    public enum WarmUpPhase: Sendable, Equatable {
        case downloading(fraction: Double?)   // downloading the real client (steamui.dll + CEF)
        case finishing                        // download committed + quiet; shutting Steam back down
    }

    /// Fold Steam's first-run self-update into setup so the user's FIRST real launch lands on the login
    /// screen — instead of the "failed to load steamui.dll" → black-window → login three-launch dance. A
    /// fresh `SteamSetup.exe /S` installs only the bootstrapper; the real client (steamui.dll + the
    /// CEF/steamwebhelper) is self-downloaded on first run. This launches Steam rootless in the BACKGROUND
    /// and waits for that download to COMMIT — not merely for the files to appear (Steam extracts them while
    /// still downloading, and shutting down then rolls the update back), but for Steam's own progress log to
    /// go quiet while the client is present — restarting Steam if it exits mid-way, then shuts it down so
    /// the caller can wrap the steamwebhelper against a settled CEF dir. Idempotent — a no-op once the client
    /// is present. Best-effort: never throws (a slow download just means setup took longer; re-running setup
    /// resumes). `onProgress` reports phases (with a real % during download).
    var warmUpPollInterval: Double = 2
    var warmUpTimeout: Double = 1200             // 20 min overall failsafe (best-effort)
    var warmUpMaxRelaunches = 3                  // resume attempts if Steam dies BEFORE committing
    var warmUpCefSettleSeconds: Double = 6       // CEF dir set unchanged this long ⇒ client finished creating them
    var warmUpBringUpTimeout: Double = 90        // cap on the post-download client bring-up
    var warmUpForceQuitSettle: Double = 2        // pause after force-quit for the wineserver to reap the procs

    func warmUpUpdate(onProgress: @escaping @MainActor (WarmUpPhase) -> Void) async {
        guard let wine = wineBinary, !bottle.isClientFullyDownloaded else { return }
        onProgress(.downloading(fraction: nil))
        bottle.resetLog()   // so `committed` reflects THIS run, not a stale marker from a prior setup
        var elapsed = 0.0
        var pid = try? await bottle.launchForUpdate(wine: wine)
        var relaunches = 0
        while elapsed < warmUpTimeout {
            try? await Task.sleep(for: .seconds(warmUpPollInterval))
            elapsed += warmUpPollInterval

            // Steam's updater state (progress + committed) in one log read.
            let state = bottle.updateState()
            onProgress(.downloading(fraction: state.progress.map {
                $0.total > 0 ? Double($0.done) / Double($0.total) : 0 }))

            // COMMITTED: Steam's updater downloaded + installed + committed the client (logged "Update
            // complete"). Only now is it safe to shut Steam down — earlier interrupts a half-applied update
            // and Steam rolls it all back. This is the ONE reliable "done" signal (a single launch does the
            // whole download→install→commit; the files appear mid-download, so their presence alone lies).
            if state.committed && bottle.isClientFullyDownloaded {
                onProgress(.finishing)
                // The download is committed, but the client creates its runtime CEF dir (e.g. cef.win64 —
                // the one Steam's login UI actually uses) only on its FIRST full run, a beat AFTER the
                // update. Shutting down + wrapping now would miss it, so the webhelper Steam runs stays
                // UNWRAPPED → black login window on the user's first real launch (until a restart re-wraps).
                // Bring the client up once and wait for its CEF dirs to settle, so the caller's wrap covers
                // cef.win64.
                await bringUpClientCef(wine: wine)
                return
            }

            // Steam exited BEFORE committing (rare — a crash / interrupted download). Resume with a fresh
            // launch (bounded); let the wineserver settle first to avoid the msync bootstrap race.
            if pid == nil || !orchestrator.isRunning(pid: pid!) {
                guard relaunches < warmUpMaxRelaunches else { break }
                relaunches += 1
                try? await Task.sleep(for: .seconds(3))
                pid = try? await bottle.launchForUpdate(wine: wine)
            }
        }
        // Failsafe / exhausted — best-effort. Shut down whatever's running; a partial download resumes on the
        // next setup run (the guard sees the client isn't fully present).
        if let live = pid { await shutDown(pid: live, wine: wine) }
    }

    /// Gracefully shut the warm-up Steam down and wait (bounded) for it to actually exit, so the caller can
    /// safely rewrite the steamwebhelper afterward. Waits for BOTH the tracked pid AND Steam's live
    /// `ActiveProcess` pid to clear — the updater re-execs a client we didn't spawn, and a lingering client
    /// holds `cef.win64/steamwebhelper.exe` open, making the wrap's file-move fail (→ unwrapped webhelper →
    /// black login window). Force-terminates the tracked pid if it overstays.
    private func shutDown(pid: Int32, wine: URL) async {
        try? await bottle.shutdownSteam(wine: wine)
        var waited = 0.0
        while orchestrator.isRunning(pid: pid) || SteamReadiness.isReady(prefix: bottle.prefix), waited < 25 {
            try? await Task.sleep(for: .milliseconds(500)); waited += 0.5
        }
        if orchestrator.isRunning(pid: pid) { orchestrator.terminate(pid: pid) }
    }

    /// Bring the (already-downloaded) client fully up ONCE so it creates its runtime CEF dir (cef.win64,
    /// the webhelper Steam's login UI uses), then shut down — so the caller's wrap covers that webhelper
    /// rather than leaving it unwrapped (→ black login window on the first real launch). Waits for the CEF
    /// dir set to stop growing (all dirs created + steady), or the client to exit, or a timeout.
    private func bringUpClientCef(wine: URL) async {
        let baseline = bottle.webHelpers().count
        // Ensure a client is up creating cef.win64 (if the updater already re-exec'd one, single-instance
        // forwarding just makes this exit — the running client is what matters, so we don't track the pid).
        _ = try? await bottle.launchForUpdate(wine: wine)
        var lastCount = baseline, stableFor = 0.0, elapsed = 0.0
        while elapsed < warmUpBringUpTimeout {
            try? await Task.sleep(for: .seconds(warmUpPollInterval)); elapsed += warmUpPollInterval
            let count = bottle.webHelpers().count
            if count > baseline, count == lastCount {
                stableFor += warmUpPollInterval
                if stableFor >= warmUpCefSettleSeconds { break }   // a new CEF dir appeared and held steady
            } else if count != lastCount {
                stableFor = 0
            }
            lastCount = count
        }
        // Force-kill the client + its webhelpers (they hold cef.win64 open) so the caller's wrap can move
        // the files — a graceful -shutdown leaves them alive under Wine.
        await bottle.forceQuit(wine: wine)
        try? await Task.sleep(for: .seconds(warmUpForceQuitSettle))   // let the wineserver reap the killed procs
    }

    private func startSteam() async {
        guard let pid = await launchSteamProcess() else { return }
        steamPID = pid
        launchError = nil
        steamObserver = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in if self?.steamPID == pid { self?.steamPID = nil } }
        }
        await awaitSteamReady()
    }

    /// Wait until the co-resident Steam client is ready for a game's Steamworks — i.e. it has registered a
    /// live `ActiveProcess` pid in the prefix's `user.reg` (the exact thing `SteamAPI_Init` reads). Resolves
    /// the INSTANT that happens via a kqueue watch on `user.reg`: no fixed wait, no polling. The
    /// `readinessTimeout` is purely a failsafe so a missing signal can't hang a launch — in normal operation
    /// the event resolves first. Returns immediately when readiness is already present or disabled (tests).
    private func awaitSteamReady() async {
        guard readinessTimeout > 0 else { return }
        let prefix = bottle.prefix
        if SteamReadiness.isReady(prefix: prefix) { return }
        let timeout = readinessTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ReadyGate(continuation)
            // Event-driven: resolve the moment Steam writes its ActiveProcess pid to user.reg.
            gate.watch = FileWatch(url: SteamReadiness.userReg(prefix: prefix)) {
                if SteamReadiness.isReady(prefix: prefix) { Task { @MainActor in gate.finish() } }
            }
            // Arm-then-check: kqueue is edge-triggered (it fires only on writes AFTER the watch is armed),
            // so a pid written in the window between the pre-check above and arming here would be missed
            // and stall the launch on the failsafe. Re-checking once after arming closes that gap.
            if SteamReadiness.isReady(prefix: prefix) { gate.finish(); return }
            // Failsafe only — guards against a never-arriving signal (or Steam dying mid-boot).
            gate.failsafe = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                gate.finish()
            }
        }
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

/// Resumes a readiness continuation exactly once (whichever of the kqueue signal / failsafe fires first),
/// tearing down the watch + cancelling the failsafe so nothing lingers. `@MainActor` so the single-resume
/// check is race-free.
@MainActor
private final class ReadyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var watch: FileWatch?
    var failsafe: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        watch = nil
        failsafe?.cancel(); failsafe = nil
        continuation.resume()
    }
}

