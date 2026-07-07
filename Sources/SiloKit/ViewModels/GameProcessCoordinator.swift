import Foundation

/// Identity of a launched game across both kinds — the single key for the coordinator's tables. A Steam
/// game is identified by BOTH its appID and its backend: the same title can be installed in both the GPTK
/// and DXMT Steam bottles (two distinct library entries), and each runs on its own bottle/runtime, so its
/// live-process state must be tracked per (appID, backend), not per appID.
enum GameID: Hashable, Sendable {
    case steam(appID: Int, backend: GraphicsBackend)
    case manual(UUID)
}

/// Owns the live-process bookkeeping for every game Silo launches — the wine-loader PID, its exit
/// observation, and the per-launch graphics-fallback monitor — in single tables keyed by `GameID`
/// (replacing the parallel Steam/manual dictionary pairs that used to live inside
/// `GameLibraryViewModel`). The library VM delegates here so load/filter/CRUD concerns don't share a
/// class with process-lifecycle state.
@MainActor
@Observable
final class GameProcessCoordinator {
    private let orchestrator: LaunchOrchestrator
    /// Crash-durable shadow of the live PIDs (see `ProcessLedger`): survives a hard crash so a relaunched
    /// Silo still refuses to move/update a bottle out from under an orphaned wineserver. nil in tests that
    /// don't exercise it.
    private let ledger: ProcessLedger?
    /// Live launch tracking (values are wine loader PIDs). Queried via `pid(for:)` / `anythingRunning`.
    private(set) var pids: [GameID: Int32] = [:]
    private var observers: [GameID: any ProcessObservation] = [:]
    /// Per-launch watchers that surface a silent backend→wined3d graphics fallback (keyed like the PIDs).
    private var monitors: [GameID: GraphicsFallbackMonitor] = [:]

    init(orchestrator: LaunchOrchestrator, ledger: ProcessLedger? = nil) {
        self.orchestrator = orchestrator
        self.ledger = ledger
    }

    /// Defensive teardown (a process-lifetime singleton in the app, so it normally never fires): cancel
    /// any live observations so they can't outlive the coordinator. `isolated` to touch @MainActor state.
    isolated deinit {
        observers.values.forEach { $0.cancel() }
        monitors.values.forEach { $0.stop() }
    }

    var anythingRunning: Bool { !pids.isEmpty }

    func pid(for id: GameID) -> Int32? { pids[id] }

    /// Track a fresh launch: remember the PID and observe its exit **without polling** (kqueue). The exit
    /// clears the tracked state — guarded by a PID match so a stale observer never clears a NEWER launch
    /// of the same game.
    func track(_ id: GameID, pid: Int32) {
        observers[id]?.cancel()
        pids[id] = pid
        ledger?.record(Self.ledgerKey(id), pid: pid)
        observers[id] = orchestrator.observeExit(pid: pid) { [weak self] in
            Task { @MainActor in
                guard let self, self.pids[id] == pid else { return }
                self.clear(id)
            }
        }
    }

    /// Watch a launch log for the silent backend→wined3d fallback; `onFallback` fires at most once, with
    /// the monitor already dropped.
    func watchGraphics(
        _ id: GameID, log: URL, backend: GraphicsBackend, onFallback: @escaping @MainActor () -> Void
    ) {
        let monitor = GraphicsFallbackMonitor()
        monitors[id] = monitor
        monitor.start(url: log, backend: backend) { [weak self] in
            self?.monitors[id] = nil
            onFallback()
        }
    }

    /// Stop tracking a game: cancel its exit observer, stop its graphics monitor, drop its PID.
    func clear(_ id: GameID) {
        pids[id] = nil
        ledger?.remove(Self.ledgerKey(id))
        observers[id]?.cancel(); observers[id] = nil
        monitors[id]?.stop(); monitors[id] = nil
    }

    /// Stop tracking a game ONLY if it's still the same launch (`pid`). Guards the case where `stop`
    /// resumes after its `taskkill` await — during which the game may have exited and been replayed — so it
    /// can't drop the NEW launch's PID (which would leave that game running but untracked).
    func clear(_ id: GameID, ifPID pid: Int32) {
        guard pids[id] == pid else { return }
        clear(id)
    }

    /// SIGTERM every tracked PID, synchronously — the app-quit path, where there's no time for the async
    /// `taskkill` cleanup. Wine turns SIGTERM into terminating the hosted game; only PIDs Silo spawned
    /// are signalled, so a co-resident Steam client is never touched.
    func terminateAllSync() {
        for (id, pid) in pids {
            orchestrator.terminate(pid: pid)
            ledger?.remove(Self.ledgerKey(id))   // intended-dead: clear now so a quick relaunch isn't blocked
        }
    }

    /// The opaque `ProcessLedger` key for a game — stable across launches so a record upserts/removes in
    /// place. (The ledger only needs a unique string per owner; it never decodes this back into a `GameID`.)
    private static func ledgerKey(_ id: GameID) -> String {
        switch id {
        case let .steam(appID, backend): "steam:\(appID):\(backend.rawValue)"
        case let .manual(uuid): "manual:\(uuid.uuidString)"
        }
    }
}
