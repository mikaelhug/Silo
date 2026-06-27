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
            steamCMD: steamCMD, orchestrator: orchestrator, configStore: ConfigStore(paths: paths),
            paths: paths, backend: backend)
        return (vm, fake, paths)
    }

    @Test("load without a signed-in account → needsLogin")
    func needsLogin() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, _) = make(tmp)
        await vm.load()
        #expect(vm.loadState == .needsLogin)
    }

    @Test("load populates the owned Windows-only catalog")
    func loadsOwned() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("License packageID 5 :\n".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(#""5" { "appids" { "0" "220" } }"#.utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(
            #""220" { "common" { "name" "Half-Life 2" "type" "Game" "oslist" "windows" } }"#.utf8)))
        vm.setAccount(username: "alice")
        await vm.load()
        #expect(vm.loadState == .loaded)
        #expect(vm.owned.map(\.appID) == [220])
    }

    @Test("isInstalled tracks the bucket's appmanifest")
    func installed() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        let info = SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])
        #expect(!vm.isInstalled(info))
        let manifests = paths.gameLibraryDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: manifests.appendingPathComponent("appmanifest_220.acf").path, contents: Data())
        #expect(vm.isInstalled(info))
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

    @Test("play is a no-op without a configured Wine backend")
    func playNeedsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp, wine: false)
        await vm.play(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"]))
        #expect(!vm.isRunning(SteamAppInfo(appID: 220, name: "HL2", oslist: ["windows"])))
        #expect(!fake.invocations.contains { $0.detached })   // never launched
    }
}
