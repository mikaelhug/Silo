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
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend)
        vm.coldStartGraceSeconds = 0   // don't wait for the (fake) Steam to "boot" in tests
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
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "SizeOnDisk" "12000000" }"#, appID: 220)
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
        #expect(vm.runningPIDs[220] == 4242)
        // The game was launched detached with WINEPREFIX forced to the shared bottle.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && ($0.arguments.first?.hasSuffix("HL2.exe") ?? false)
        })

        await vm.stop(game)
        #expect(!vm.isRunning(game))
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
}
