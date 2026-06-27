import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("GameLibraryViewModel")
struct GameLibraryViewModelTests {

    private func make(_ tmp: TempDir, wine: Bool = true)
        -> (GameLibraryViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        try? FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        let steamCMD = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(
            runner: fake, provisioner: PrefixProvisioner(runner: fake, paths: paths),
            linker: GraphicsLinker(), logStore: GameLogStore(paths: paths))
        var backend = BackendConfig()
        if wine { backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64") }
        let vm = GameLibraryViewModel(
            steamCMD: steamCMD, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), cache: LibraryCacheStore(paths: paths),
            paths: paths, backend: backend)
        return (vm, fake, paths)
    }

    /// Write a manifest where SteamCMD's force_install_dir actually puts it:
    /// <gameLibrary>/steamapps/common/<appID>/steamapps/appmanifest_<appID>.acf
    private func writeManifest(_ paths: AppPaths, _ acf: String, appID: Int) throws {
        let nested = paths.gameInstallDir(forAppID: appID).appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try acf.write(to: nested.appendingPathComponent("appmanifest_\(appID).acf"),
                      atomically: true, encoding: .utf8)
    }

    @Test("load without a signed-in account → needsLogin")
    func needsLogin() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, _) = make(tmp)
        await vm.load()
        #expect(vm.loadState == .needsLogin)
    }

    @Test("refresh enumerates owned Windows-playable games (incl. Mac-capable) and persists to cache")
    func refreshesOwned() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("License packageID 5 :\n".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(#""5" { "appids" { "0" "220" "1" "70" } }"#.utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("""
        "70"  { "common" { "name" "Half-Life" "type" "Game" "oslist" "windows,macos" } }
        "220" { "common" { "name" "Half-Life 2" "type" "Game" "oslist" "windows" } }
        """.utf8)))
        vm.setAccount(username: "alice")
        await vm.performRefresh(username: "alice")

        #expect(vm.loadState == .loaded)
        #expect(vm.owned.map(\.appID) == [70, 220])      // both run on Windows (HL also has Mac)
        // Windows-only toggle hides the Mac-capable one.
        vm.showWindowsOnly = true
        #expect(vm.filtered.map(\.appID) == [220])
        // Persisted to the cache.
        let cached = await LibraryCacheStore(paths: paths).load()
        #expect(cached?.games.map(\.appID).sorted() == [70, 220])
    }

    @Test("load shows the cached catalog instantly (before any SteamCMD call)")
    func loadsFromCache() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        await LibraryCacheStore(paths: paths).save(
            username: "alice",
            games: [SteamAppInfo(appID: 730, name: "CS", oslist: ["windows"], type: "game")], at: Date())
        vm.setAccount(username: "alice")
        await vm.load()
        #expect(vm.owned.map(\.appID) == [730])           // shown from cache, no enumeration needed
        #expect(vm.loadState == .loaded)
        _ = fake   // (refresh runs in the background; we only assert the instant cache path here)
    }

    @Test("install state: parses bucket appmanifests for installed size + live download progress")
    func installState() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "SizeOnDisk" "12000000" }"#, appID: 220)
        try writeManifest(paths, #""AppState" { "appid" "70" "name" "HL" "StateFlags" "1048578" "installdir" "HL" "SizeOnDisk" "0" "BytesDownloaded" "50" "BytesToDownload" "100" }"#, appID: 70)
        await vm.load()   // username nil → just refreshes install state

        let hl2 = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])
        let hl = SteamAppInfo(appID: 70, name: "HL", oslist: ["windows"])
        #expect(vm.isInstalled(hl2))
        #expect(vm.sizeString(hl2) != nil)
        #expect(!vm.isInstalled(hl))
        #expect(vm.downloadProgress(hl) == 0.5)   // from the nested manifest's bytes
    }

    @Test("download delegates to SteamCMD app_update for the game's bucket")
    func download() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        vm.setAccount(username: "alice")
        await vm.download(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"]))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments.contains("+app_update"))
        #expect(call.arguments.contains("220"))
        #expect(call.arguments.contains("windows"))
    }

    @Test("interrupted download → paused (resumable); active appmanifest flag → re-attached on launch")
    func pauseAndReattach() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        // 220: partial + no active flag (e.g. network dropped / app closed mid-download) → resumable.
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "2" "installdir" "HL2" "BytesDownloaded" "30" "BytesToDownload" "100" }"#, appID: 220)
        // 70: a SteamCMD `app_update 70` is still running (e.g. orphaned) → re-attach to it.
        try writeManifest(paths, #""AppState" { "appid" "70" "name" "HL" "StateFlags" "2" "installdir" "HL" "BytesDownloaded" "50" "BytesToDownload" "100" }"#, appID: 70)
        fake.matchingProcesses = ["app_update 70"]
        await vm.load()

        let hl2 = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])
        let hl = SteamAppInfo(appID: 70, name: "HL", oslist: ["windows"])
        #expect(vm.isPaused(hl2));      #expect(!vm.isDownloading(hl2))   // resumable
        #expect(vm.isDownloading(hl));  #expect(!vm.isPaused(hl))         // re-attached, live
    }

    @Test("cancel stops tracking and removes the partial bucket")
    func cancelDownload() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        vm.setAccount(username: "alice")
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"], type: "game")
        await vm.download(info)
        #expect(vm.isDownloading(info))
        #expect(FileManager.default.fileExists(atPath: paths.gameInstallDir(forAppID: 220).path))

        await vm.cancel(info)
        #expect(!vm.isDownloading(info))
        #expect(!FileManager.default.fileExists(atPath: paths.gameInstallDir(forAppID: 220).path))
    }

    /// Spin the main actor until `condition` holds or we give up (lets event-driven hops settle).
    private func settle(until condition: @escaping () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("an interrupted download (SteamCMD exits before completion) becomes resumable, not lost")
    func downloadInterrupted() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        vm.setAccount(username: "alice")
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"], type: "game")
        await vm.download(info)
        #expect(vm.isDownloading(info))

        // SteamCMD wrote a partial manifest, then its process died (e.g. lost network) — no "fully installed".
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "1026" "installdir" "HL2" "BytesDownloaded" "30" "BytesToDownload" "100" }"#, appID: 220)
        fake.setAlive(4242, false)   // process-exit observer fires (no polling)

        await settle { !vm.isDownloading(info) }
        #expect(!vm.isDownloading(info))
        #expect(vm.isPaused(info))   // the partial is kept → "Resume", never silently dropped
    }

    @Test("a launched game clears its running state on process exit (event-driven, no poll)")
    func gameExitClearsState() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        let bucket = paths.gameInstallDir(forAppID: 220)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bucket.appendingPathComponent("game.exe").path, contents: Data("MZ".utf8))
        let prefix = paths.prefix(forAppID: 220)
        fake.onRun = { _ in
            let layout = PrefixLayout(prefix: prefix)
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            try? "reg".write(to: layout.systemReg, atomically: true, encoding: .utf8)
        }
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])
        await vm.play(info)
        #expect(vm.isRunning(info))

        fake.setAlive(4242, false)   // the game process exits → observeExit handler clears it
        await settle { !vm.isRunning(info) }
        #expect(!vm.isRunning(info))
    }

    @Test("uninstall deletes the game files AND its prefix, and clears installed state")
    func uninstall() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "SizeOnDisk" "12000000" }"#, appID: 220)
        // A pre-existing isolated prefix for the game (created by a prior launch).
        try FileManager.default.createDirectory(at: paths.prefix(forAppID: 220), withIntermediateDirectories: true)
        await vm.load()
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])
        #expect(vm.isInstalled(info))
        #expect(FileManager.default.fileExists(atPath: paths.gameInstallDir(forAppID: 220).path))

        await vm.uninstall(info)
        #expect(!vm.isInstalled(info))
        #expect(!FileManager.default.fileExists(atPath: paths.gameInstallDir(forAppID: 220).path))
        #expect(!FileManager.default.fileExists(atPath: paths.prefix(forAppID: 220).path))   // prefix nuked too
    }

    @Test("uninstall clears the game's saved settings so a reinstall starts fresh")
    func uninstallClearsConfig() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        let store = ConfigStore(paths: paths)
        var cfg = GameConfig(appID: 220); cfg.backend = .crossover; cfg.customArgs = ["-foo"]
        try await store.saveGame(cfg)
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "SizeOnDisk" "12000000" }"#, appID: 220)
        await vm.load()

        await vm.uninstall(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"]))
        let reloaded = await store.load().config(for: 220)
        #expect(reloaded.backend == .gptk)        // back to the default backend
        #expect(reloaded.customArgs.isEmpty)      // saved launch options gone
    }

    @Test("addManualGame adds an off-catalog game to the library and installs it")
    func addManualGame() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        vm.setAccount(username: "alice")
        await vm.addManualGame(appID: 99999, name: "My Game")

        let info = SteamAppInfo(appID: 99999, name: "My Game", oslist: ["windows"])
        #expect(vm.owned.contains { $0.appID == 99999 })   // now in the displayed library
        #expect(vm.isDownloading(info))                    // and a download was kicked off
        #expect(fake.invocations.contains { $0.detached && $0.arguments.contains("99999") })
    }

    @Test("play is a no-op without a configured Wine backend")
    func playNeedsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp, wine: false)
        await vm.play(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"]))
        #expect(!vm.isRunning(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])))
        #expect(!fake.invocations.contains { $0.detached })   // never launched
    }

    @Test("play launches an installed game in its bucket; stop clears it")
    func playStop() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        let bucket = paths.gameInstallDir(forAppID: 220)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bucket.appendingPathComponent("game.exe").path, contents: Data("MZ".utf8))
        let prefix = paths.prefix(forAppID: 220)
        fake.onRun = { _ in   // simulate wineboot creating the prefix so provisioning succeeds
            let layout = PrefixLayout(prefix: prefix)
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            try? "reg".write(to: layout.systemReg, atomically: true, encoding: .utf8)
        }
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])

        await vm.play(info)
        #expect(vm.isRunning(info))
        #expect(vm.runningPIDs[220] == 4242)

        await vm.stop(info)
        #expect(!vm.isRunning(info))
    }
}
