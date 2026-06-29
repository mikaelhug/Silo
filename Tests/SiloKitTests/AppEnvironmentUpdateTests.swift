import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("AppEnvironment update + backend fan-out")
struct AppEnvironmentUpdateTests {

    /// A releases LIST with an app release newer than 0.0.1 (so bootstrap's checkForUpdate sees an update).
    private let newerJSON = """
    [{"tag_name":"v9.9.9","name":"Silo 9.9.9","assets":[
      {"name":"Silo.app.zip","browser_download_url":"https://example.com/Silo.app.zip","size":1}]}]
    """

    // MARK: - installUpdate

    @Test("installUpdate fails cleanly (no process work) when not running from an .app bundle")
    func installUpdateNoBundle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        FakeURLProtocol.stub("https://api.github.com/repos/test/env-update-newer/releases?per_page=30",
                             data: Data(newerJSON.utf8))
        let runner = FakeProcessRunner()
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "test/env-update-newer", currentVersion: "0.0.1",
                             session: FakeURLProtocol.makeSession(), runner: runner))
        await env.bootstrap()
        #expect(env.updateCheck?.isNewer == true)

        let before = runner.invocations.count
        await env.installUpdate()

        // Under `swift test`, runningAppBundle() is nil (the xctest bundle has no .app ancestor):
        // the bundle guard fires BEFORE any download/install.
        guard case let .failed(msg) = env.updateState else {
            Issue.record("expected .failed, got \(env.updateState)"); return
        }
        #expect(msg.contains("installed app bundle"))
        // No ditto/open leaked — the guard short-circuited before any process work.
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "ditto" })
        #expect(!runner.invocations.contains { $0.executable.lastPathComponent == "open" })
        #expect(runner.invocations.count == before)
    }

    @Test("installUpdate is a no-op when no newer release is available")
    func installUpdateNotNewer() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let sameJSON = """
        [{"tag_name":"v0.0.1","name":"Silo 0.0.1","assets":[
          {"name":"Silo.app.zip","browser_download_url":"https://example.com/Silo.app.zip","size":1}]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/test/env-update-same/releases?per_page=30",
                             data: Data(sameJSON.utf8))
        let runner = FakeProcessRunner()
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "test/env-update-same", currentVersion: "0.0.1",
                             session: FakeURLProtocol.makeSession(), runner: runner))
        await env.bootstrap()
        #expect(env.updateCheck?.isNewer == false)

        let before = runner.invocations.count
        await env.installUpdate()
        #expect(env.updateState == .idle)               // early return, never entered .downloading
        #expect(runner.invocations.count == before)     // zero process work
    }

    @Test("checkForUpdate re-queries GitHub and updates updateCheck")
    func manualCheckForUpdate() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        FakeURLProtocol.stub("https://api.github.com/repos/test/manual-check/releases?per_page=30",
                             data: Data(newerJSON.utf8))
        let runner = FakeProcessRunner()
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "test/manual-check", currentVersion: "0.0.1",
                             session: FakeURLProtocol.makeSession(), runner: runner))
        #expect(env.updateCheck == nil)            // didn't bootstrap, so no auto-check yet

        await env.checkForUpdate()

        #expect(env.updateCheck?.isNewer == true)  // the manual check found the v9.9.9 release
        #expect(!env.isCheckingForUpdate)
    }

    // MARK: - applyBackend fan-out

    @Test("AppEnvironment fans a backend change out to BOTH the library and the Steam-bottle pane")
    func backendFanOut() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())

        // Both sinks start un-configured (no persisted config, no wine).
        #expect(!env.gameLibrary.canLaunch)
        #expect(!env.steamBottleVM.canSetUp)   // wineBinary == nil

        // Drive a backend change exactly as the UI does: mutate config, then save().
        // save() persists, then fires onChange -> AppEnvironment.applyBackend -> both sinks.
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        await env.backendSettings.save()

        #expect(env.gameLibrary.canLaunch)        // sink 1
        #expect(env.steamBottleVM.canSetUp)       // sink 2 — the previously-untested half
    }

    @Test("AppEnvironment wires a Wine-Manager default change through to the backend sinks")
    func defaultWineChangeWiring() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        #expect(env.runtime.onDefaultChanged != nil)
        #expect(env.gptkManager.onDefaultChanged != nil)
        #expect(!env.steamBottleVM.canSetUp)

        // Simulate the Wine Manager publishing a new default. AppEnvironment.init wired
        // runtime.onDefaultChanged -> applyDefaultWine -> save() -> onChange -> applyBackend.
        let install = WineInstall(
            name: "wine-cx-26",
            installDir: tmp.url.appendingPathComponent("wine"),
            wineBinary: URL(fileURLWithPath: "/w/bin/wine64"))
        env.runtime.onDefaultChanged?(install)

        // The callback dispatches via `Task { await ... }`, so await the async hop before asserting.
        for _ in 0..<50 where !env.steamBottleVM.canSetUp { await Task.yield() }
        #expect(env.steamBottleVM.canSetUp)       // the new default reached the bottle pane
        #expect(env.gameLibrary.canLaunch)        // ...and the library
    }
}
