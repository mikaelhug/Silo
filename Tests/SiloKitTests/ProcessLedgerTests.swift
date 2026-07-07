import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("ProcessLedger")
struct ProcessLedgerTests {

    private func make(_ tmp: TempDir) -> (ProcessLedger, FakeProcessRunner, URL) {
        let url = tmp.url.appendingPathComponent("Silo/running-processes.json")
        let fake = FakeProcessRunner()
        return (ProcessLedger(url: url, runner: fake), fake, url)
    }

    @Test("a recorded live process is a survivor; removing it clears the ledger")
    func recordAndRemove() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, fake, url) = make(tmp)
        fake.setAlive(100, true)

        ledger.record("steam:220:gptk", pid: 100)
        #expect(ledger.hasLiveSurvivor())
        #expect(FileManager.default.fileExists(atPath: url.path))

        ledger.remove("steam:220:gptk")
        #expect(!ledger.hasLiveSurvivor())
        #expect(!FileManager.default.fileExists(atPath: url.path))   // empty ⇒ file removed
    }

    @Test("a dead PID is not a survivor and is pruned in passing")
    func deadPidPruned() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, fake, url) = make(tmp)
        fake.setAlive(100, true)
        ledger.record("g", pid: 100)

        fake.setAlive(100, false)                 // the process exited (crash left the record behind)
        #expect(!ledger.hasLiveSurvivor())
        #expect(!FileManager.default.fileExists(atPath: url.path))   // self-healed
    }

    @Test("a REUSED PID (same pid, different start time) is treated as dead — never a false block")
    func reusedPidIsNotAlive() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, fake, _) = make(tmp)
        fake.setAlive(100, true)
        ledger.record("g", pid: 100)              // captures start time A
        #expect(ledger.hasLiveSurvivor())

        // The orphan died and PID 100 was recycled by an unrelated process — alive again, but a DIFFERENT
        // start time. The (pid, startTime) identity must reject it so the gate doesn't block forever.
        fake.setStartTime(100, Date(timeIntervalSince1970: 1))
        #expect(!ledger.hasLiveSurvivor())
    }

    @Test("record is a no-op for an already-dead PID (nothing to guard)")
    func recordDeadPidNoOp() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, _, url) = make(tmp)
        ledger.record("g", pid: 999)              // never marked alive ⇒ no start time
        #expect(!ledger.hasLiveSurvivor())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("survivors mixed with dead: hasLiveSurvivor is true and prunes only the dead one")
    func mixedSurvivors() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, fake, url) = make(tmp)
        fake.setAlive(100, true); fake.setAlive(200, true)
        ledger.record("live", pid: 100)
        ledger.record("dead", pid: 200)
        fake.setAlive(200, false)

        #expect(ledger.hasLiveSurvivor())                 // 100 keeps it alive
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The dead entry is gone: removing the still-live one now empties the ledger.
        ledger.remove("live")
        #expect(!ledger.hasLiveSurvivor())
    }

    @Test("re-recording the same key upserts (one entry), not duplicates")
    func recordUpserts() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, fake, _) = make(tmp)
        fake.setAlive(100, true); fake.setAlive(101, true)
        ledger.record("g", pid: 100)
        ledger.record("g", pid: 101)              // same owner relaunched with a new PID
        #expect(ledger.hasLiveSurvivor())
        // One entry under "g": removing it (once) clears everything.
        ledger.remove("g")
        #expect(!ledger.hasLiveSurvivor())
    }

    @Test("fail-open: a corrupt or absent ledger reports nothing running")
    func failOpen() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (ledger, _, url) = make(tmp)
        #expect(!ledger.hasLiveSurvivor())                // absent
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json ".utf8).write(to: url)
        #expect(!ledger.hasLiveSurvivor())                // garbage ⇒ nothing, never a crash
    }
}
