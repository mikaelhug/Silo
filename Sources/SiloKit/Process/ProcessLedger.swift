import Foundation

/// A **crash-durable** record of the OS processes Silo has launched into a Wine bottle — the games it runs
/// co-resident in a Steam bottle, and the Steam clients themselves.
///
/// In normal operation the in-memory PID maps (`GameProcessCoordinator`, `SteamClientSession`) are the
/// source of truth and this just shadows them. Its whole reason to exist is the **hard-crash** path: if
/// Silo dies without running its clean-quit teardown, those maps are gone on the next launch — but the
/// wine processes may still be alive. Moving or self-updating a bottle out from under a live wineserver
/// corrupts it, so the relocation/update gate consults `hasLiveSurvivor()` and a relaunched Silo still
/// refuses while a prior run's process is alive.
///
/// Identity is `(pid, startTime)`: a recycled PID whose start time no longer matches is treated as dead,
/// so the ledger never *falsely* reports liveness after PID reuse (which would wrongly block the user
/// forever). Everything is best-effort + **fail-open**: an unreadable/absent ledger reports nothing
/// running, so a persistence glitch can never leave the user unable to move bottles or update.
@MainActor
public final class ProcessLedger {
    private let url: URL
    private let runner: ProcessRunning

    public init(url: URL, runner: ProcessRunning) {
        self.url = url
        self.runner = runner
    }

    private struct Entry: Codable, Sendable {
        var key: String     // opaque owner key (e.g. "steam:220:gptk", "client:dxmt") — for upsert/remove
        var pid: Int32
        var start: Double   // process start time (Unix seconds); with `pid` a reuse-proof identity
    }

    /// Record (or replace) the live process owned by `key`, capturing its start time so a later reuse of
    /// the PID can't masquerade as this process. No-op if the PID has no resolvable start time (it's
    /// already gone) — there'd be nothing durable to guard.
    func record(_ key: String, pid: Int32) {
        guard let start = runner.startTime(pid: pid) else { return }
        var entries = load().filter { $0.key != key }
        entries.append(Entry(key: key, pid: pid, start: start.timeIntervalSince1970))
        write(entries)
    }

    /// Drop the process recorded under `key` (it exited cleanly or was stopped).
    func remove(_ key: String) {
        let entries = load()
        guard entries.contains(where: { $0.key == key }) else { return }   // avoid a needless rewrite
        write(entries.filter { $0.key != key })
    }

    /// Whether any recorded process is still alive. Prunes dead/reused entries as a side effect, so the
    /// ledger self-heals every time the gate is read. Fail-open: an unreadable ledger reports nothing.
    func hasLiveSurvivor() -> Bool {
        let entries = load()
        let alive = entries.filter(isAlive)
        if alive.count != entries.count { write(alive) }   // prune the dead in passing
        return !alive.isEmpty
    }

    // MARK: - identity

    private func isAlive(_ entry: Entry) -> Bool {
        guard runner.isRunning(pid: entry.pid), let now = runner.startTime(pid: entry.pid) else { return false }
        // Same PID AND (near-)identical start time ⇒ the same process instance we recorded. The epsilon
        // only absorbs JSON double-rounding of an otherwise-constant `p_starttime`; a reused PID belongs to
        // a process that started *after* the recorded one died, far outside this window.
        return abs(now.timeIntervalSince1970 - entry.start) < 1.5
    }

    // MARK: - storage (best-effort, fail-open)

    private func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
