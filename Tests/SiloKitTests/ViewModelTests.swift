import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("View models")
struct ViewModelTests {

    @Test("BackendSettings autodetect finds Whisky in temp dirs and save fires onChange")
    func backendSettings() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let apps = try tmp.makeDir("apps")
        try tmp.write("home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64", "x")

        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = BackendSettingsViewModel(
            config: BackendConfig(), resolver: BackendResolver(), configStore: ConfigStore(paths: paths),
            paths: paths)
        var propagated: BackendConfig?
        vm.onChange = { propagated = $0 }

        vm.autodetect(homeDirectory: home, applicationsDirectory: apps)
        #expect(vm.config.detectedSource == .whisky)

        await vm.save()
        #expect(propagated?.detectedSource == .whisky)
        #expect(await ConfigStore(paths: paths).load().backend.detectedSource == .whisky)
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
          {"tag_name":"v0.1.0","name":"Silo 0.1.0","assets":[
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

    @Test("AppEnvironment.setupComplete needs Wine + GPTK + Steam sign-in")
    func setupComplete() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let env = AppEnvironment(
            paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")),
            runner: FakeProcessRunner())
        #expect(!env.setupComplete)
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        env.backendSettings.config.gptkLibDirPath = URL(fileURLWithPath: "/g/lib")
        #expect(!env.setupComplete)                       // not signed in to Steam yet
        env.backendSettings.config.steamUsername = "alice"
        #expect(env.setupComplete)
        #expect(env.wineReady && env.gptkReady && env.steamLoggedIn)
    }

    @Test("AppEnvironment bootstraps from persisted config")
    func appEnvironment() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        var backend = BackendConfig(detectedSource: .manual)
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        try await ConfigStore(paths: paths).saveBackend(backend)

        let env = AppEnvironment(
            paths: paths, runner: FakeProcessRunner(),
            updater: Updater(repo: "x/y", session: FakeURLProtocol.makeSession()))
        await env.bootstrap()
        #expect(env.didBootstrap)
        #expect(env.backendSettings.config.detectedSource == .manual)
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
