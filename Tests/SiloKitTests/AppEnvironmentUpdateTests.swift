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

    @Test("BackendServices: one bundle per backend, each internally consistent; forwards match")
    func backendBundles() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let env = AppEnvironment(
            paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")),
            runner: FakeProcessRunner())
        #expect(env.backends.count == GraphicsBackend.allCases.count)
        for backend in GraphicsBackend.allCases {
            let services = env.services(for: backend)
            #expect(services.backend == backend)
            #expect(services.bottle.backend == backend)   // the bundle can't cross-wire bottles
            #expect(services.session.backend == backend)
        }
        // The pre-bundle convenience names resolve to the SAME objects as the keyed table.
        #expect(env.steamBottleVM === env.services(for: .gptk).bottleVM)
        #expect(env.dxmtBottleVM === env.services(for: .dxmt).bottleVM)
        #expect(env.steamClientSession === env.services(for: .gptk).session)
        #expect(env.dxmtClientSession === env.services(for: .dxmt).session)
    }

    @Test("a fresh Steam install flips the library's cached steamReady gate (onSteamInstalled wiring)")
    func steamInstallFlipsLibraryGate() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        FakeURLProtocol.stub("https://api.github.com/repos/test/env-wiring/releases?per_page=30",
                             data: Data("[]".utf8))
        let runner = FakeProcessRunner()
        let env = AppEnvironment(
            paths: paths, runner: runner,
            updater: Updater(repo: "test/env-wiring", currentVersion: "0.0.1",
                             session: FakeURLProtocol.makeSession(), runner: runner))
        await env.bootstrap()
        #expect(env.gameLibrary.loadState == .notReady)   // no bottle yet
        #expect(!env.steamReady)

        // Put Steam's exe in the bottle out-of-band, then run the VM's setUp: installSteam sees it
        // already installed (no download) and the success path fires onSteamInstalled → library reload.
        try FileManager.default.createDirectory(
            at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        env.steamBottleVM.updateWine(URL(fileURLWithPath: "/w/wine64"))
        await env.steamBottleVM.setUp()
        #expect(env.steamBottleVM.steamInstalled)

        // The wiring reloads the library in a fire-and-forget Task — bounded wait for the gate to flip.
        // A missed invalidation here would permanently stall onboarding (the regression this test pins).
        for _ in 0..<200 where !env.steamReady {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(env.steamReady)
        #expect(env.gameLibrary.loadState != .notReady)
    }

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
        #expect(env.updates.updateCheck?.isNewer == true)

        let before = runner.invocations.count
        await env.updates.installUpdate()

        // Under `swift test`, runningAppBundle() is nil (the xctest bundle has no .app ancestor):
        // the bundle guard fires BEFORE any download/install.
        guard case let .failed(msg) = env.updates.updateState else {
            Issue.record("expected .failed, got \(env.updates.updateState)"); return
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
        #expect(env.updates.updateCheck?.isNewer == false)

        let before = runner.invocations.count
        await env.updates.installUpdate()
        #expect(env.updates.updateState == .idle)               // early return, never entered .downloading
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
        #expect(env.updates.updateCheck == nil)            // didn't bootstrap, so no auto-check yet

        await env.updates.checkForUpdate()

        #expect(env.updates.updateCheck?.isNewer == true)  // the manual check found the v9.9.9 release
        #expect(!env.updates.isCheckingForUpdate)
    }

    // MARK: - Bottles relocation

    @Test("moveBottles relocates the bottle dirs, persists the new root, asks for a restart (no bundle in tests)")
    func moveBottles() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        // A provisioned Steam bottle at the default location.
        try FileManager.default.createDirectory(
            at: paths.steamBottle.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: paths.steamBottle.appendingPathComponent("marker").path, contents: Data("x".utf8))

        let dest = try tmp.makeDir("External")
        await env.bottles.moveBottles(to: dest)

        let newRoot = dest.appendingPathComponent("Silo Bottles")
        #expect(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("SteamBottle/marker").path))
        #expect(!FileManager.default.fileExists(atPath: paths.steamBottle.appendingPathComponent("marker").path))
        #expect(BottlesLocation.read(supportDir: paths.supportDir)?.path == newRoot.path)   // override persisted
        #expect(env.bottles.message?.contains("Restart") == true)   // no .app bundle under swift test
        #expect(!env.bottles.busy)
    }

    @Test("moveBottles refuses an exFAT/FAT destination (no move, no persist)")
    func moveBottlesRefusesFAT() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        env.bottles.filesystemRejects = { _ in true }   // simulate the destination being exFAT
        try FileManager.default.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        let dest = try tmp.makeDir("FATDrive")

        await env.bottles.moveBottles(to: dest)

        #expect(env.bottles.message?.lowercased().contains("exfat") == true)
        #expect(!FileManager.default.fileExists(           // not moved
            atPath: dest.appendingPathComponent("Silo Bottles/SteamBottle").path))
        #expect(BottlesLocation.read(supportDir: paths.supportDir) == nil)   // not persisted
        #expect(!env.bottles.busy)
    }

    @Test("resetBottlesLocation moves bottles back to the default and clears the override")
    func resetBottles() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let support = tmp.url.appendingPathComponent("Silo")
        let ext = tmp.url.appendingPathComponent("External/Silo Bottles")
        // An env that already lives at a relocated root (i.e. as if relaunched there).
        let env = AppEnvironment(
            paths: AppPaths(supportDir: support, bottlesRoot: ext), runner: FakeProcessRunner())
        try FileManager.default.createDirectory(
            at: ext.appendingPathComponent("ManualBottles/uuid"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: ext.appendingPathComponent("ManualBottles/uuid/m").path, contents: Data())
        BottlesLocation.write(ext, supportDir: support)

        await env.bottles.resetBottlesLocation()

        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("ManualBottles/uuid/m").path))
        #expect(BottlesLocation.read(supportDir: support) == nil)   // override cleared → default
    }

    // MARK: - applyBackend fan-out

    @Test("importDXMTRuntime adopts a valid DXMT module folder and rejects an incomplete one")
    func importsDXMTRuntime() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        #expect(!env.dxmtReady)

        // Incomplete folder (no winemetal.dll) is rejected.
        let bad = try tmp.makeDir("bad"); try tmp.write("bad/d3d11.dll", "x")
        await env.importDXMTRuntime(from: bad)
        #expect(!env.dxmtReady)

        // A complete DXMT module folder is adopted + persisted.
        let good = try tmp.makeDir("dxmt-win")
        try tmp.write("dxmt-win/d3d11.dll", "x"); try tmp.write("dxmt-win/winemetal.dll", "x")
        await env.importDXMTRuntime(from: good)
        #expect(env.dxmtReady)
        #expect(env.backendSettings.config.dxmtLibDirPath == good)
    }

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

        // Simulate the Wine tab publishing a new default. AppEnvironment.init wired
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
