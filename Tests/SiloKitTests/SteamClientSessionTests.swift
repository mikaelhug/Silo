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
}
