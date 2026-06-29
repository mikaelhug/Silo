import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("GameLibraryViewModel")
struct GameLibraryViewModelTests {

    private func make(_ tmp: TempDir, wine: Bool = true)
        -> (GameLibraryViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig()
        if wine { backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64") }
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath)
        session.coldStartGraceSeconds = 0   // don't wait for the (fake) Steam to "boot" in tests
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session)
        return (vm, fake, paths)
    }

    /// Mark the bottle's Steam as installed (so the library is "ready").
    private func installSteam(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
    }

    /// Write a game manifest into the bottle's Steam library.
    private func writeManifest(_ paths: AppPaths, _ acf: String, appID: Int) throws {
        let steamapps = paths.steamBottleClientDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try acf.write(to: steamapps.appendingPathComponent("appmanifest_\(appID).acf"),
                      atomically: true, encoding: .utf8)
    }

    private func installedGame(_ paths: AppPaths, appID: Int, name: String, dir: String) throws -> SteamApp {
        let common = paths.steamBottleClientDir.appendingPathComponent("steamapps/common/\(dir)")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: common.appendingPathComponent("\(dir).exe").path, contents: Data("MZ".utf8))
        return SteamApp(appID: appID, name: name, installDir: dir,
                        stateFlags: .fullyInstalled, sizeOnDisk: 100, libraryPath: paths.steamBottleClientDir)
    }

    @Test("load discovers games installed in the bottle's Steam library")
    func loadsInstalledGames() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try installSteam(paths)
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "LastOwner" "76561197960287930" "SizeOnDisk" "12000000" }"#, appID: 220)
        await vm.load()
        #expect(vm.loadState == .loaded)
        #expect(vm.games.map(\.appID) == [220])
    }

    @Test("load → notReady when the bottle has no Steam installed")
    func notReadyWithoutSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, _) = make(tmp)
        await vm.load()
        #expect(vm.loadState == .notReady)
    }

    @Test("play launches the game co-resident in the bottle prefix")
    func playInBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)
        #expect(vm.isRunning(game))
        // Steam cold-starts first (PID 4242), so the game loader is the next spawn (4243).
        let loaderPID = try #require(vm.runningPIDs[220])
        #expect(loaderPID == 4243)
        // The game was launched detached with WINEPREFIX forced to the shared bottle.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && ($0.arguments.first?.hasSuffix("HL2.exe") ?? false)
        })

        await vm.stop(game)
        #expect(!vm.isRunning(game))
        // Stop SIGTERMs the launched loader (not just taskkill) — proving both halves of the contract.
        #expect(fake.terminatedPIDs.contains(loaderPID))
        // Stop also taskkills the game's image (in the bottle's msync wineserver) so a child/relauncher
        // isn't orphaned — without clobbering the co-resident Steam.
        #expect(fake.invocations.contains {
            $0.arguments == ["taskkill", "/F", "/IM", "HL2.exe"] && $0.environment["WINEMSYNC"] == "1"
        })
    }

    @Test("a game exiting on its own clears the running state")
    func gameExitClearsState() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(vm.isRunning(game))

        let pid = try #require(vm.runningPIDs[220])
        fake.setAlive(pid, false)   // simulate the game process exiting
        for _ in 0..<20 where vm.isRunning(game) { await Task.yield() }   // let the @MainActor handler run
        #expect(!vm.isRunning(game))
    }

    @Test("manual games: add, play in the bottle (no Steam needed), then remove")
    func manualGameLifecycle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        await vm.load()                                  // an empty Steam library
        #expect(vm.loadState == .empty)

        // The user points at an installed/portable .exe anywhere on disk.
        let exe = try tmp.write("Games/Cool/Cool.exe", "MZ")
        let game = try #require(await vm.addManualGame(name: "Cool Game", executable: exe))
        #expect(vm.manualGames.map(\.name) == ["Cool Game"])
        #expect(vm.loadState == .loaded)                 // a manual game makes the library non-empty

        await vm.playManual(game)
        #expect(vm.isRunning(game))
        let pid = try #require(vm.manualRunningPIDs[game.id])
        // Spawned detached into the SHARED bottle prefix, with the absolute exe — and NO Steam cold-start
        // (a manual game never calls session.ensureRunning).
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && $0.arguments.first == exe.path
        })
        #expect(!fake.invocations.contains { $0.arguments.first?.hasSuffix("steam.exe") ?? false })

        await vm.stopManual(game)
        #expect(!vm.isRunning(game))
        #expect(fake.terminatedPIDs.contains(pid))

        await vm.removeManual(game)
        #expect(vm.manualGames.isEmpty)
        #expect(vm.loadState == .empty)                  // empty again once both lists are empty
    }

    @Test("addManualGame defaults the name to the exe filename and persists across a reload")
    func manualGameDefaultNameAndPersistence() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try installSteam(paths)
        let exe = try tmp.write("Portable/Witness.exe", "MZ")
        _ = await vm.addManualGame(name: "   ", executable: exe)   // blank → default to filename
        #expect(vm.manualGames.first?.name == "Witness")

        await vm.load()                                  // reload from config.json
        #expect(vm.manualGames.map(\.name) == ["Witness"])   // persisted
    }

    @Test("two games launched at once start the bottle Steam only once")
    func concurrentPlayLaunchesSteamOnce() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        async let pa: Void = vm.play(a)
        async let pb: Void = vm.play(b)
        _ = await (pa, pb)

        // The Steam client launch is the virtual desktop + CEF flags — there must be exactly ONE, not one per game.
        let steamLaunches = fake.invocations.filter {
            $0.arguments.first == "explorer" && $0.arguments.contains("-cef-in-process-gpu")
        }
        #expect(steamLaunches.count == 1)
    }

    @Test("settings 'Launch Steam' then a game Play share ONE tracked client (no double-spawn)")
    func sharedSteamClientNoDoubleSpawn() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig(); backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        // ONE shared session — exactly how AppEnvironment wires the Library + the settings pane.
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath); session.coldStartGraceSeconds = 0
        let library = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session)
        let settings = SteamBottleViewModel(bottle: bottle, session: session)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await settings.launchSteam()   // the formerly-untracked spawn path
        await library.play(game)       // previously this cold-started a SECOND Steam client

        #expect(steamCEFLaunches(fake) == 1)   // ONE client — shared + tracked across both view models
        #expect(library.isRunning(game))
    }

    @Test("play is a no-op without a configured Wine backend")
    func playNeedsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp, wine: false)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(!vm.isRunning(game))
        #expect(!fake.invocations.contains { $0.detached })   // nothing launched
    }

    @Test("install opens the bottle's Steam to the game's install dialog")
    func installViaSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        await vm.install(appID: 730)
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments.contains("steam://install/730"))
    }

    @Test("uninstall asks the bottle's Steam to remove the game")
    func uninstallViaSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.uninstall(game)
        let call = try #require(fake.lastInvocation)
        #expect(call.arguments.contains("steam://uninstall/220"))
    }

    @Test("uninstall is a no-op while the game is running")
    func uninstallNoOpWhileRunning() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)                          // launches the game → runningPIDs[220] set
        #expect(vm.isRunning(game))

        await vm.uninstall(game)                      // guard !isRunning must short-circuit

        // No steam://uninstall URL was ever sent for a running game.
        #expect(!fake.invocations.contains { $0.arguments.contains("steam://uninstall/220") })
        #expect(vm.isRunning(game))                  // still running, untouched
    }

    /// Count the bottle-Steam (CEF) launches recorded by the runner.
    private func steamCEFLaunches(_ fake: FakeProcessRunner) -> Int {
        fake.invocations.filter {
            $0.arguments.first == "explorer" && $0.arguments.contains("-cef-in-process-gpu")
        }.count
    }

    @Test("a second Play with Steam already up does not relaunch Steam")
    func secondPlayReusesRunningSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        await vm.play(a)   // cold-starts Steam (first spawn, alive) + launches A
        await vm.play(b)   // Steam already up → isRunning short-circuit, NOT a relaunch
        #expect(steamCEFLaunches(fake) == 1)
    }

    @Test("a Play after the bottle Steam exits cold-starts Steam again")
    func playAfterSteamExitRestartsSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        await vm.play(a)
        #expect(steamCEFLaunches(fake) == 1)

        // ensureSteamRunning() runs before the game launch, so Steam is the FIRST detached spawn (PID 4242).
        // Kill it → the steamObserver nulls steamPID.
        #expect(fake.invocations.first { $0.detached }?.arguments.contains("-cef-in-process-gpu") == true)
        fake.setAlive(4242, false)
        // Let the @MainActor exit observer run (it nulls steamPID).
        for _ in 0..<50 { await Task.yield() }

        await vm.play(b)                            // steamPID nil now → cold-starts Steam again
        #expect(steamCEFLaunches(fake) == 2)
    }

    @Test("play surfaces a launch failure to statusMessage without sticking the game busy/running")
    func playLaunchFailureSurfacesStatus() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)                       // past the wine/steam guards
        // A game whose install dir has NO exe → orchestrator.launchInBottle throws executableNotFound.
        let game = SteamApp(appID: 220, name: "HL2", installDir: "Nope",
                            stateFlags: .fullyInstalled, sizeOnDisk: 100,
                            libraryPath: paths.steamBottleClientDir)

        await vm.play(game)

        #expect(!vm.isRunning(game))                  // never reached runningPIDs[id] = pid
        #expect(!vm.isBusy(game))                     // defer cleared busyAppIDs
        #expect(vm.runningPIDs[220] == nil)
        #expect(vm.statusMessage?.contains("HL2") == true)   // the catch surfaced "<name>: <error>"
        // The game itself was never spawned detached (resolution failed before spawn).
        #expect(!fake.invocations.contains {
            $0.detached && ($0.arguments.first?.hasSuffix("Nope.exe") ?? false)
        })
    }
}
