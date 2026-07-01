import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("View models")
struct ViewModelTests {

    @Test("BackendSettings save persists the config and fires onChange")
    func backendSettings() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = BackendSettingsViewModel(
            config: BackendConfig(), configStore: ConfigStore(paths: paths))
        var propagated: BackendConfig?
        vm.onChange = { propagated = $0 }

        vm.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        await vm.save()
        #expect(propagated?.wineBinaryPath?.path == "/w/wine64")
        #expect(await ConfigStore(paths: paths).load().backend.wineBinaryPath?.path == "/w/wine64")
    }

    @Test("GameSettings save reports success and clears any earlier error")
    func gameSettingsSaveSucceeds() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = GameSettingsViewModel(config: GameConfig(appID: 220), configStore: ConfigStore(paths: paths))
        vm.config.customArgs = ["-novid"]
        #expect(await vm.save())
        #expect(vm.errorMessage == nil)
        #expect(await ConfigStore(paths: paths).load().config(for: 220).customArgs == ["-novid"])
    }

    @Test("GameSettings save failure returns false + surfaces errorMessage (sheet must NOT dismiss)")
    func gameSettingsSaveFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A FILE where the support DIR must go → ConfigStore.save's createDirectory throws.
        let supportDir = tmp.url.appendingPathComponent("Silo")
        FileManager.default.createFile(atPath: supportDir.path, contents: Data())
        let paths = AppPaths(supportDir: supportDir)
        let vm = GameSettingsViewModel(config: GameConfig(appID: 220), configStore: ConfigStore(paths: paths))
        #expect(await vm.save() == false)
        #expect(vm.errorMessage?.contains("Couldn't save") == true)
    }

    @Test("RuntimeViewModel lists installed Wine builds")
    func runtimeVM() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("Silo/Runtimes/Wine-9.0/bin/wine64", "x")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner()), repo: "acme/wine")
        await vm.refresh()
        #expect(vm.installed.map(\.name) == ["Wine-9.0"])
        #expect(vm.installed.first?.wineBinary?.lastPathComponent == "wine64")
    }

    @Test("installLatest installs the newest wine-* release, ignoring app v* releases in the same repo")
    func wineReleaseFilter() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [
          {"tag_name":"v0.5.0","name":"Silo 0.5.0","assets":[
            {"name":"Silo.zip","browser_download_url":"https://e.com/Silo.zip","size":1}]},
          {"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[
            {"name":"wine.tar.xz","browser_download_url":"https://e.com/wf.tar.xz","size":1}]}
        ]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/winefilter/releases?per_page=15", data: Data(json.utf8))
        FakeURLProtocol.stub("https://e.com/wf.tar.xz", data: Data("WINE".utf8))
        let fake = FakeProcessRunner()
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let bin = URL(fileURLWithPath: inv.arguments[i + 1]).appendingPathComponent("bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
            }
        }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession()),
            repo: "acme/winefilter")
        await vm.installLatest()
        #expect(vm.installed.map(\.name) == ["wine-cx-26.2.0"])
    }

    @Test("installLatest does NOT re-download when the latest Wine is already installed")
    func installLatestAlreadyInstalled() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [ {"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[
            {"name":"wine.tar.xz","browser_download_url":"https://e.com/already.tar.xz","size":1}]} ]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/already/releases?per_page=15", data: Data(json.utf8))
        // Deliberately do NOT stub the asset URL — a download would fail, proving we don't attempt one.
        let fake = FakeProcessRunner()
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        // The latest build is already on disk.
        let bin = paths.runtimesDir.appendingPathComponent("wine-cx-26.2.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: fake, session: FakeURLProtocol.makeSession()),
            repo: "acme/already")
        await vm.refresh()                                   // installed now lists wine-cx-26.2.0

        await vm.installLatest()

        #expect(vm.statusMessage?.contains("already installed") == true)
        #expect(vm.installed.map(\.name) == ["wine-cx-26.2.0"])             // unchanged
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "tar" })   // no extraction
    }

    @Test("installLatest reports 'No Wine build published' when the repo has no wine-* release")
    func installLatestNoWineRelease() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let json = """
        [{"tag_name":"v0.5.0","name":"Silo 0.5.0","assets":[
          {"name":"Silo.zip","browser_download_url":"https://e.com/Silo.zip","size":1}]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/noWine/releases?per_page=15", data: Data(json.utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession()),
            repo: "acme/noWine")
        await vm.installLatest()
        #expect(vm.statusMessage?.contains("No Wine build published") == true)
        #expect(!vm.isInstalling)
    }

    @Test("installLatest reports 'no installable archive' when the wine-* release has no archive asset")
    func installLatestNoAsset() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let json = """
        [{"tag_name":"wine-cx-26.2.0","name":"Wine CX 26.2.0","assets":[]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/noAsset/releases?per_page=15", data: Data(json.utf8))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession()),
            repo: "acme/noAsset")
        await vm.installLatest()
        #expect(vm.statusMessage?.contains("no installable archive") == true)
        #expect(!vm.isInstalling)
    }

    @Test("AppEnvironment.setupComplete needs Wine + GPTK + the Steam bottle")
    func setupComplete() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        #expect(!env.setupComplete)
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        env.backendSettings.config.gptkLibDirPath = URL(fileURLWithPath: "/g/lib")
        #expect(!env.setupComplete)                       // Steam not installed in the bottle yet
        try FileManager.default.createDirectory(at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        #expect(env.setupComplete)
        #expect(env.wineReady && env.gptkReady && env.steamReady)
    }

    @Test("AppEnvironment bootstraps from persisted config")
    func appEnvironment() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        try await ConfigStore(paths: paths).saveBackend(backend)

        let env = AppEnvironment(
            paths: paths, runner: FakeProcessRunner(),
            updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()))
        await env.bootstrap()
        #expect(env.didBootstrap)
        #expect(env.backendSettings.config.wineBinaryPath?.path == "/w/wine64")
        #expect(env.gameLibrary.canLaunch)
        #expect(env.updateCheck == nil)
    }

    @Test("ExecutableResolver.allExecutables lists exes shallowest-first")
    func allExecutables() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let game = try tmp.makeDir("G")
        try tmp.write("G/Game.exe", "x")
        try tmp.write("G/redist/vcredist.exe", "x")
        let list = ExecutableResolver.allExecutables(in: game)
        #expect(list.first == "Game.exe")
        #expect(list.contains("redist/vcredist.exe"))
    }
}
