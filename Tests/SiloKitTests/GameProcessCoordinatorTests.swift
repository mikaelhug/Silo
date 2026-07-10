import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("GameProcessCoordinator")
struct GameProcessCoordinatorTests {

    private func make() -> (GameProcessCoordinator, FakeProcessRunner) {
        let fake = FakeProcessRunner()
        let coordinator = GameProcessCoordinator(
            orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        return (coordinator, fake)
    }

    /// Bounded wait for an exit-handler's main-actor hop to land.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("track remembers the PID; a kqueue exit clears it")
    func trackAndExit() async throws {
        let (coordinator, fake) = make()
        coordinator.track(.steam(appID: 220), pid: 4242)
        #expect(coordinator.pid(for: .steam(appID: 220)) == 4242)
        #expect(coordinator.anythingRunning)

        fake.setAlive(4242, false)   // fires the observeExit handler
        try await waitUntil { coordinator.pid(for: .steam(appID: 220)) == nil }
        #expect(coordinator.pid(for: .steam(appID: 220)) == nil)
        #expect(!coordinator.anythingRunning)
    }

    @Test("a STALE exit never clears a newer launch of the same game (pid-match guard)")
    func staleExitGuard() async throws {
        let (coordinator, fake) = make()
        coordinator.track(.steam(appID: 220), pid: 1000)
        fake.setAlive(1000, false)                    // old exit enqueues its main-actor hop…
        coordinator.track(.steam(appID: 220), pid: 2000)     // …but a relaunch wins the race
        for _ in 0..<20 { await Task.yield() }        // let the stale hop land
        #expect(coordinator.pid(for: .steam(appID: 220)) == 2000)   // guarded: the new launch stays tracked
        #expect(coordinator.anythingRunning)
    }

    @Test("re-track cancels the previous observer outright")
    func retrackCancelsObserver() async throws {
        let (coordinator, fake) = make()
        coordinator.track(.manual(UUID(0)), pid: 1000)
        coordinator.track(.manual(UUID(0)), pid: 2000)   // same game relaunched
        fake.setAlive(1000, false)                       // the cancelled observer must not fire at all
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.pid(for: .manual(UUID(0))) == 2000)
    }

    @Test("clear drops the PID, cancels the observer, and stops the graphics monitor")
    func clearStopsEverything() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, fake) = make()
        let id = GameID.manual(UUID())
        let log = tmp.url.appendingPathComponent("g.log")
        coordinator.track(id, pid: 4242)
        let fired = LockedBox(false)
        coordinator.watchGraphics(id, log: log, backend: .gptk) { fired.set(true) }

        coordinator.clear(id)
        #expect(coordinator.pid(for: id) == nil)

        // The stopped monitor must NOT fire on a late fallback signature…
        let handle = try FileHandle(forWritingTo: log)   // the monitor created the file on start
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("err:winediag: Using the Vulkan renderer\n".utf8))
        try handle.close()
        for _ in 0..<50 { await Task.yield() }
        #expect(!fired.value)
        // …and the cleared game's exit is inert.
        fake.setAlive(4242, false)
        for _ in 0..<20 { await Task.yield() }
        #expect(!coordinator.anythingRunning)
    }

    @Test("watchGraphics fires onFallback once when the wined3d signature is (already) in the log")
    func graphicsFallbackFires() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, _) = make()
        let log = tmp.url.appendingPathComponent("f.log")
        try Data("err:winediag: Using the Vulkan renderer\n".utf8).write(to: log)
        let count = LockedBox(0)
        coordinator.watchGraphics(.steam(appID: 220), log: log, backend: .gptk) { count.set(count.value + 1) }
        try await waitUntil { count.value == 1 }
        #expect(count.value == 1)
    }

    @Test("terminateAllSync SIGTERMs exactly the tracked PIDs (Steam + manual)")
    func terminateAll() throws {
        let (coordinator, fake) = make()
        coordinator.track(.steam(appID: 220), pid: 100)
        coordinator.track(.manual(UUID()), pid: 200)
        coordinator.terminateAllSync()
        #expect(Set(fake.terminatedPIDs) == [100, 200])
    }

    /// A coordinator wired to a real `ProcessLedger` over a temp file, plus that ledger + fake runner.
    private func makeWithLedger(_ tmp: TempDir) -> (GameProcessCoordinator, ProcessLedger, FakeProcessRunner) {
        let fake = FakeProcessRunner()
        let ledger = ProcessLedger(url: tmp.url.appendingPathComponent("running.json"), runner: fake)
        let coordinator = GameProcessCoordinator(
            orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()), ledger: ledger)
        return (coordinator, ledger, fake)
    }

    @Test("track shadows the launch into the crash-durable ledger")
    func ledgerRecordsOnTrack() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, ledger, fake) = makeWithLedger(tmp)
        fake.setAlive(4242, true)                  // the ledger only records a live PID (it reads its start time)
        #expect(!ledger.hasLiveSurvivor())
        coordinator.track(.steam(appID: 220), pid: 4242)
        #expect(ledger.hasLiveSurvivor())
    }

    @Test("clear does NOT drop a still-alive ledger entry — only confirmed death / self-prune does")
    func ledgerKeptWhileAlive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, ledger, fake) = makeWithLedger(tmp)
        fake.setAlive(4242, true)
        coordinator.track(.manual(UUID(1)), pid: 4242)
        #expect(ledger.hasLiveSurvivor())
        coordinator.clear(.manual(UUID(1)))
        #expect(ledger.hasLiveSurvivor())          // still alive ⇒ still recorded (a stop is not a death)
        fake.setAlive(4242, false)                 // the process actually exits
        #expect(!ledger.hasLiveSurvivor())         // now self-pruned
    }

    @Test("a kqueue exit removes the ledger entry (confirmed death)")
    func ledgerRemovedOnExit() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, ledger, fake) = makeWithLedger(tmp)
        fake.terminateKeepsPIDAlive = true          // so only the kqueue exit (not a prune) can clear it
        fake.setAlive(4242, true)
        coordinator.track(.steam(appID: 220), pid: 4242)
        #expect(ledger.hasLiveSurvivor())
        fake.setAlive(4242, false)                  // fires the exit observer
        try await waitUntil { coordinator.pid(for: .steam(appID: 220)) == nil }
        #expect(!ledger.hasLiveSurvivor())
    }

    @Test("terminateAllSync does NOT drop a ledger entry whose process survives the SIGTERM (quit-orphan safety)")
    func ledgerSurvivesStubbornQuit() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (coordinator, ledger, fake) = makeWithLedger(tmp)
        fake.terminateKeepsPIDAlive = true          // the game ignores/slow-processes SIGTERM
        fake.setAlive(100, true)
        coordinator.track(.steam(appID: 220), pid: 100)
        coordinator.terminateAllSync()
        #expect(fake.terminatedPIDs.contains(100))  // SIGTERM was sent…
        #expect(ledger.hasLiveSurvivor())           // …but the still-alive process stays recorded → next launch's gate refuses
    }

}

private extension UUID {
    /// A deterministic UUID for tests that need the SAME id across two calls.
    init(_ seed: UInt8) {
        self.init(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
