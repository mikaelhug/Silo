import Foundation
import Testing
@testable import SiloKit

/// Exercises the event-driven Steam-readiness gate LIVE (`readinessTimeout > 0`) — the kqueue watch, the
/// arm-then-check, and the failsafe — rather than short-circuiting it with `readinessTimeout = 0` the way
/// the operational tests do. Uses a real temp `user.reg` so `SteamReadiness` reads an actual file.
@MainActor
@Suite("SteamClientSession readiness")
struct SteamClientSessionTests {

    private func make(_ tmp: TempDir) -> (SteamClientSession, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let session = SteamClientSession(
            bottle: bottle, orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        session.updateWine(URL(fileURLWithPath: "/w/wine64"))   // fake path: webhelper wrapper is a no-op
        return (session, paths)
    }

    /// Write the bottle's `user.reg` with `ActiveProcess` carrying `pid` — in place (truncate+write) so an
    /// update fires the kqueue `.write` event, exactly as Wine's in-place registry save does.
    private func setActivePid(_ paths: AppPaths, _ pid: UInt32) throws {
        let prefix = paths.steamBottle
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let body = Data("""
        WINE REGISTRY Version 2

        [Software\\Valve\\Steam\\ActiveProcess]
        "pid"=dword:\(String(pid, radix: 16))
        """.utf8)
        let url = prefix.appendingPathComponent("user.reg")
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: body)
        } else {
            try body.write(to: url)
        }
    }

    @Test("ready instantly when Steam's ActiveProcess pid is already live")
    func readyImmediately() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (session, paths) = make(tmp)
        try setActivePid(paths, 0x1234)
        session.readinessTimeout = 10               // generous failsafe; must NOT be the one that resolves

        let clock = ContinuousClock()
        let start = clock.now
        let running = await session.ensureRunning()

        #expect(running)
        #expect(clock.now - start < .seconds(1))    // resolved via the pre-check, not the 10s failsafe
    }

    @Test("resolves promptly when Steam writes its pid AFTER the wait begins (kqueue watch fires)")
    func resolvesOnWrite() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (session, paths) = make(tmp)
        try setActivePid(paths, 0)                  // file exists (watchable) but no live pid yet
        session.readinessTimeout = 10               // failsafe ceiling — a working watch resolves far sooner

        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { await session.ensureRunning() }
        try await Task.sleep(for: .milliseconds(80))   // let the wait arm its watch
        try setActivePid(paths, 0x1234)             // flip to a live pid → the watch fires
        let running = await task.value

        #expect(running)
        #expect(clock.now - start < .seconds(5))    // far under the 10s failsafe → the watch resolved it
    }

    @Test("failsafe resolves the wait when the readiness signal never arrives")
    func failsafeFallback() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (session, paths) = make(tmp)
        try setActivePid(paths, 0)                  // never flipped to a live pid
        session.readinessTimeout = 0.3

        let clock = ContinuousClock()
        let start = clock.now
        let running = await session.ensureRunning()

        #expect(running)                            // failsafe lets the launch proceed rather than hang
        #expect(clock.now - start >= .seconds(0.25))   // it actually waited the failsafe, not an instant return
    }

    @Test("stop() cancels a client caught MID-SPAWN — it self-terminates instead of becoming a 2nd client")
    func stopCancelsMidSpawnBringUp() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let session = SteamClientSession(
            bottle: SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths),
            orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        session.updateWine(URL(fileURLWithPath: "/w/wine64"))
        session.readinessTimeout = 0
        // Hold the spawn in flight so we can `stop()` before the session adopts the PID.
        let gate = OneShotGate()
        fake.onSpawnAwait = { await gate.wait() }

        let launching = Task { await session.ensureRunning() }
        for _ in 0..<500 where fake.invocations.isEmpty { await Task.yield() }   // spawn is now in flight
        session.stop()             // cross-bottle teardown cancels the in-flight bring-up
        await gate.open()          // let the spawn return its PID
        let up = await launching.value

        #expect(!up)               // the bring-up did NOT adopt the client…
        #expect(!session.isRunning)
        #expect(!fake.terminatedPIDs.isEmpty)   // …it terminated the process it had spawned (no 2nd client)
    }

    // MARK: - Warm-up (first-run self-update folded into setup)

    /// A fresh-bootstrapper session (steam.exe present, no client yet) + its fake runner + paths.
    private func makeWarmUp(_ tmp: TempDir) -> (SteamClientSession, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let session = SteamClientSession(
            bottle: bottle, orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        session.updateWine(URL(fileURLWithPath: "/w/wine64"))
        session.warmUpPollInterval = 0.01
        session.warmUpCefSettleSeconds = 0.02
        session.warmUpBringUpTimeout = 0.1   // the fake bring-up creates a new CEF dir, so this rarely caps
        session.warmUpForceQuitSettle = 0
        try? FileManager.default.createDirectory(at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        return (session, fake, paths)
    }

    /// Simulate Steam downloading + COMMITTING the client (steamui.dll + a CEF steamwebhelper on disk, plus
    /// the updater's "Update complete" marker in the log) on the update launch, and quitting on `-shutdown`.
    private func simulateDownload(_ fake: FakeProcessRunner, _ paths: AppPaths) {
        fake.onRun = { inv in
            let fm = FileManager.default
            // A Steam LAUNCH has the steam.exe path as its first arg (a taskkill's `/IM steam.exe` doesn't).
            guard inv.arguments.first?.hasSuffix("steam.exe") == true else { return }
            let client = paths.steamBottleClientDir
            let cef7 = client.appendingPathComponent("bin/cef/cef.win7x64")
            if !fm.fileExists(atPath: cef7.path) {
                // First launch = download: steamui.dll + the cef.win7x64 webhelper + the commit marker.
                try? fm.createDirectory(at: cef7, withIntermediateDirectories: true)
                fm.createFile(atPath: client.appendingPathComponent("steamui.dll").path, contents: Data("x".utf8))
                fm.createFile(atPath: cef7.appendingPathComponent("steamwebhelper.exe").path, contents: Data("x".utf8))
                let log = paths.steamBottleLog(.gptk)
                try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "Downloading update (100 of 100 KB)...\nUpdate complete, launching Steam...\n"
                    .write(to: log, atomically: true, encoding: .utf8)
            } else {
                // Bring-up launch: the client creates its runtime CEF dir (cef.win64) — the whole point of
                // the bring-up, so the wrap covers it.
                let cef64 = client.appendingPathComponent("bin/cef/cef.win64")
                try? fm.createDirectory(at: cef64, withIntermediateDirectories: true)
                fm.createFile(atPath: cef64.appendingPathComponent("steamwebhelper.exe").path, contents: Data("x".utf8))
            }
        }
    }

    @Test("warmUpUpdate downloads the full client (no -silent), settles, then shuts Steam down")
    func warmUpDownloadsClient() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (session, fake, paths) = makeWarmUp(tmp)
        simulateDownload(fake, paths)

        var phases: [SteamClientSession.WarmUpPhase] = []
        await session.warmUpUpdate { phases.append($0) }

        // Launched steam.exe for the update WITHOUT `-silent` (which would skip the first-run download).
        let launch = fake.invocations.first { $0.detached && $0.arguments.contains { $0.hasSuffix("steam.exe") } }
        #expect(launch != nil)
        #expect(launch?.arguments.contains("-silent") == false)
        // Must NOT carry the verify/repair-skip flags — on a fresh bootstrapper those skip the download and
        // pop the "failed to load steamui.dll" fatal dialog.
        #expect(launch?.arguments.contains("-noverifyfiles") == false)
        #expect(launch?.arguments.contains("-norepairfiles") == false)
        // Reached the fully-downloaded state; brought the client up (creating the cef.win64 dir Steam runs)
        // then force-quit it so the caller's wrap can cover that webhelper.
        #expect(SteamBottle(runner: fake, paths: paths).isClientFullyDownloaded)
        #expect(FileManager.default.fileExists(atPath:
            paths.steamBottleClientDir.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe").path))
        #expect(fake.invocations.contains { $0.arguments.contains("taskkill") })
        #expect(phases.contains { if case .downloading = $0 { true } else { false } })
        #expect(phases.contains(.finishing))
    }

    @Test("warmUpUpdate shadows its download client into the ledger (crash-during-setup safety)")
    func warmUpRecordsClientToLedger() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let ledger = ProcessLedger(url: paths.processLedgerFile, runner: fake)
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let session = SteamClientSession(
            bottle: bottle, orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()),
            ledger: ledger)
        session.updateWine(URL(fileURLWithPath: "/w/wine64"))
        session.warmUpPollInterval = 0.005
        session.warmUpTimeout = 0.05        // never commits → exits via the failsafe quickly
        session.warmUpMaxRelaunches = 0
        session.warmUpForceQuitSettle = 0
        try FileManager.default.createDirectory(at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())

        // The download client is alive AND recorded during the warm-up — observed via onProgress, before the
        // failsafe shutdown tears it down. A crash in this window would otherwise orphan an untracked client.
        let sawSurvivor = LockedBox(false)
        await session.warmUpUpdate { _ in if ledger.hasLiveSurvivor() { sawSurvivor.set(true) } }
        #expect(sawSurvivor.value)
    }

    @Test("warmUpUpdate is a no-op when the client is already fully downloaded")
    func warmUpNoOpWhenPresent() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (session, fake, paths) = makeWarmUp(tmp)
        // Pre-stage a complete client.
        let cef = paths.steamBottleClientDir.appendingPathComponent("bin/cef/cef.win7x64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleClientDir.appendingPathComponent("steamui.dll").path, contents: Data())
        FileManager.default.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())

        await session.warmUpUpdate { _ in }

        #expect(!fake.invocations.contains { $0.detached })   // never launched Steam — nothing to download
    }
}

/// A one-shot async barrier for tests: `wait()` suspends until `open()` (returns immediately if already
/// opened). Used to hold a fake spawn "in flight" while the test drives a mid-spawn race.
actor OneShotGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        guard !opened else { return }
        opened = true
        continuation?.resume(); continuation = nil
    }
}
