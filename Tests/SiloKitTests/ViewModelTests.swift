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

    @Test("RuntimeViewModel lists installed runtimes")
    func runtimeVM() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.makeDir("Silo/Runtimes/GPTK-2.1/bin")
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let runner = FakeProcessRunner()
        let vm = RuntimeViewModel(
            manager: RuntimeManager(paths: paths, runner: runner),
            repo: "acme/gptk",
            gptkImporter: GPTKImporter(runner: runner, paths: paths))
        await vm.refreshInstalled()
        #expect(vm.installed.map(\.name) == ["GPTK-2.1"])
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
