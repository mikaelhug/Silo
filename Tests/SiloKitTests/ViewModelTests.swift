import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("View models")
struct ViewModelTests {

    /// Build a temp Master bottle with a Steam tree containing the given manifests.
    private func makeBottle(_ tmp: TempDir, manifests: [String]) throws -> URL {
        let bottle = tmp.url.appendingPathComponent("bottle")
        let steamapps = DiscoveryEngine.steamRoot(inBottle: bottle)
            .appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        for fixture in manifests {
            try (try FixtureLoader.text(fixture))
                .write(to: steamapps.appendingPathComponent(fixture), atomically: true, encoding: .utf8)
        }
        return bottle
    }

    private func makeLibrary(_ tmp: TempDir, backend: BackendConfig, runner: ProcessRunning = FakeProcessRunner())
        -> LibraryViewModel {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let provisioner = PrefixProvisioner(runner: runner, paths: paths)
        let logStore = GameLogStore(paths: paths)
        return LibraryViewModel(
            discovery: DiscoveryEngine(),
            orchestrator: LaunchOrchestrator(runner: runner, provisioner: provisioner,
                                             linker: GraphicsLinker(), logStore: logStore),
            configStore: ConfigStore(paths: paths),
            provisioner: provisioner,
            libraryInstaller: SteamLibraryInstaller(runner: runner),
            backend: backend)
    }

    @Test("Library refresh loads games when a bottle is configured")
    func refreshLoads() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let bottle = try makeBottle(tmp, manifests: ["appmanifest_220.acf", "appmanifest_570.acf"])
        var backend = BackendConfig()
        backend.masterBottlePath = bottle
        let library = makeLibrary(tmp, backend: backend)

        await library.refresh()
        #expect(library.loadState == .loaded)
        #expect(library.games.count == 2)
    }

    @Test("Library refresh reports an error when no bottle is configured")
    func refreshNoBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let library = makeLibrary(tmp, backend: BackendConfig())
        await library.refresh()
        if case .error = library.loadState { } else { Issue.record("expected .error, got \(library.loadState)") }
        #expect(library.games.isEmpty)
    }

    @Test("Library search filters by name")
    func search() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let bottle = try makeBottle(tmp, manifests: ["appmanifest_220.acf", "appmanifest_570.acf"])
        var backend = BackendConfig()
        backend.masterBottlePath = bottle
        let library = makeLibrary(tmp, backend: backend)
        await library.refresh()

        library.searchText = "dota"
        #expect(library.filteredGames.map(\.name) == ["Dota 2"])
        library.searchText = ""
        #expect(library.filteredGames.count == 2)
    }

    @Test("canLaunch reflects wine configuration")
    func canLaunch() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        var backend = BackendConfig()
        #expect(makeLibrary(tmp, backend: backend).canLaunch == false)
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        #expect(makeLibrary(tmp, backend: backend).canLaunch == true)
    }

    @Test("BackendSettings autodetect finds Whisky in temp dirs and save fires onChange")
    func backendSettings() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let home = try tmp.makeDir("home")
        let apps = try tmp.makeDir("apps")
        try tmp.write("home/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64", "x")

        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = BackendSettingsViewModel(
            config: BackendConfig(), resolver: BackendResolver(), configStore: ConfigStore(paths: paths),
            steamInstaller: SteamBottleInstaller(runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession()),
            paths: paths)

        var propagated: BackendConfig?
        vm.onChange = { propagated = $0 }

        vm.autodetect(homeDirectory: home, applicationsDirectory: apps)
        #expect(vm.config.detectedSource == .whisky)

        await vm.save()
        #expect(propagated?.detectedSource == .whisky)
        // Persisted to disk.
        #expect(await ConfigStore(paths: paths).load().backend.detectedSource == .whisky)
    }

    @Test("RuntimeViewModel lists installed Wine builds")
    func runtimeVM() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("Silo/Runtimes/Wine-9.0/bin/wine64", "x")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: FakeProcessRunner()),
            repo: "acme/wine")
        await vm.refresh()
        #expect(vm.installed.map(\.name) == ["Wine-9.0"])
        #expect(vm.installed.first?.wineBinary?.lastPathComponent == "wine64")
    }

    @Test("AppEnvironment.setupComplete reflects configured runtimes")
    func setupComplete() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let env = AppEnvironment(
            paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")),
            runner: FakeProcessRunner())
        #expect(!env.setupComplete)
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        env.backendSettings.config.gptkLibDirPath = URL(fileURLWithPath: "/g/lib")
        #expect(!env.setupComplete)               // Steam bottle still missing
        env.backendSettings.config.masterBottlePath = URL(fileURLWithPath: "/b")
        #expect(env.setupComplete)
        #expect(env.wineReady && env.gptkReady && env.steamReady)
    }

    @Test("RuntimeViewModel.installLatest installs the newest release and sets it default")
    func installLatest() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [{"tag_name":"Wine-9.0","name":"Wine 9.0","assets":[
          {"name":"wine-9.0.tar.xz","browser_download_url":"https://e.com/w.tar.xz","size":1}]}]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/wine/releases?per_page=3", data: Data(json.utf8))
        FakeURLProtocol.stub("https://e.com/w.tar.xz", data: Data("A".utf8))
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
            repo: "acme/wine")
        var defaulted: WineInstall?
        vm.onDefaultChanged = { defaulted = $0 }

        await vm.installLatest()
        #expect(vm.installed.map(\.name) == ["Wine-9.0"])
        #expect(defaulted?.name == "Wine-9.0")
    }

    @Test("openSteam launches steam.exe with CEF crash-workaround flags")
    func openSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let env = AppEnvironment(
            paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")), runner: fake)
        env.backendSettings.config.masterBottlePath = URL(fileURLWithPath: "/b")
        env.backendSettings.config.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")

        await env.openSteam()
        let call = try #require(fake.invocations.last { $0.detached })
        #expect(call.arguments.first?.hasSuffix("steam.exe") == true)
        #expect(call.arguments.contains("-cef-disable-gpu"))
        #expect(call.arguments.contains("-cef-force-32bit"))
        #expect(call.environment["WINEPREFIX"] == "/b")
    }

    @Test("AppEnvironment bootstraps from persisted config")
    func appEnvironment() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        // Pre-seed a backend config.
        var backend = BackendConfig(detectedSource: .manual)
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        try await ConfigStore(paths: paths).saveBackend(backend)

        let env = AppEnvironment(paths: paths, runner: FakeProcessRunner())
        await env.bootstrap()
        #expect(env.didBootstrap)
        #expect(env.backendSettings.config.detectedSource == .manual)
        #expect(env.library.canLaunch)
    }
}
