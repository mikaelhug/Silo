import Foundation
import Testing
@testable import SiloKit

@Suite("LaunchOrchestrator.makePlan (pure)")
struct MakePlanTests {
    let app = SteamApp(appID: 220, name: "HL2", installDir: "Half-Life 2",
                       stateFlags: .fullyInstalled, sizeOnDisk: 1,
                       libraryPath: URL(fileURLWithPath: "/lib"))
    let prefix = URL(fileURLWithPath: "/p/220")
    let log = URL(fileURLWithPath: "/p/220.log")
    let gameExe = URL(fileURLWithPath: "/lib/steamapps/common/Half-Life 2/hl2.exe")

    private func backend(gptk: String? = "/w/wine64", cx: String? = "/cx/wine") -> BackendConfig {
        var b = BackendConfig()
        b.wineBinaryPath = gptk.map { URL(fileURLWithPath: $0) }
        b.crossoverWinePath = cx.map { URL(fileURLWithPath: $0) }
        return b
    }

    @Test("GPTK plan: bottle WINEPREFIX, sync flags, no DXVK overrides, custom args, cwd")
    func gptkPlan() throws {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        cfg.envFlags = EnvFlags(syncMode: .msync)
        cfg.customArgs = ["-dev", "-w", "1920"]
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)

        #expect(plan.executable.path == "/w/wine64")
        #expect(plan.arguments == [gameExe.path, "-dev", "-w", "1920"])
        #expect(plan.environment["WINEPREFIX"] == "/p/220")        // the shared Steam-bottle prefix
        #expect(plan.environment["WINEMSYNC"] == "1")          // MSync default on Apple Silicon
        #expect(plan.environment["WINEESYNC"] == nil)          // mutually exclusive — not both
        #expect(plan.environment["WINEDLLOVERRIDES"] == nil)        // GPTK injects D3DMetal, no DXVK
        #expect(plan.environment["WINEDEBUG"] == "-all")           // quiet default
        #expect(plan.currentDirectory.path == "/lib/steamapps/common/Half-Life 2")
        #expect(plan.logURL == log)
    }

    @Test("Bottle launch forces msync even if the game is configured for esync (one shared wineserver)")
    func forcesMsyncForCoResidency() throws {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        cfg.envFlags = EnvFlags(syncMode: .esync)   // user picked ESync…
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        // …but a bottle game MUST match Steam's msync or it gets its own wineserver and loses Steamworks.
        #expect(plan.environment["WINEMSYNC"] == "1")
        #expect(plan.environment["WINEESYNC"] == nil)
    }

    @Test("GPTK plan with GPTK configured: D3DMetal on DYLD fallbacks + builtin d3d via WINEDLLPATH")
    func gptkPlanD3DMetalWiring() throws {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        var b = backend()
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")  // <root>/lib/wine/x86_64-windows
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: b, gameExe: gameExe, prefix: prefix, logURL: log)

        // libd3dshared.dylib + D3DMetal.framework live in <root>/lib/external — must lead the DYLD paths.
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix("/g/lib/external:") == true)
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/silo-bundled") == true)
        #expect(plan.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] == "/g/lib/external")
        // GPTK's builtin d3d modules come from <root>/lib/wine, selected as builtin.
        #expect(plan.environment["WINEDLLPATH"] == "/g/lib/wine")
        #expect(plan.environment["WINEDLLOVERRIDES"]?.contains("d3d11") == true)
        #expect(plan.environment["WINEDLLOVERRIDES"]?.contains("=b") == true)
    }

    @Test("CrossOver plan: selects crossover wine and sets DXVK DLL overrides")
    func crossoverPlan() throws {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .crossover
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        #expect(plan.executable.path == "/cx/wine")
        #expect(plan.environment["WINEDLLOVERRIDES"]?.contains("dxgi=n") == true)
    }

    @Test("User WINEDEBUG via extra flags is preserved")
    func customWineDebug() throws {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags = EnvFlags(extra: ["WINEDEBUG": "+seh,+tid"])
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        #expect(plan.environment["WINEDEBUG"] == "+seh,+tid")
    }

    @Test("Throws wineNotConfigured when no wine binary is available")
    func notConfigured() {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        #expect(throws: LaunchOrchestrator.LaunchError.wineNotConfigured) {
            try LaunchOrchestrator.makePlan(
                app: app, config: cfg, backend: backend(gptk: nil, cx: nil),
                gameExe: gameExe, prefix: prefix, logURL: log)
        }
    }
}

@Suite("LaunchOrchestrator.launch (pipeline)")
struct LaunchPipelineTests {

    @Test("Links graphics + spawns the game detached into the shared bottle prefix")
    func fullPipeline() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())

        // Fake GPTK lib dir + a fake install tree with the exe + the shared (bottle) prefix.
        let gptkDir = try tmp.makeDir("gptk")
        try tmp.write("gptk/D3DMetal.dll", "x")
        let lib = try tmp.makeDir("lib")
        try tmp.write("lib/steamapps/common/Half-Life 2/hl2.exe", "MZ")
        let prefix = try tmp.makeDir("bottle")

        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        backend.gptkLibDirPath = gptkDir

        let app = SteamApp(appID: 220, name: "HL2", installDir: "Half-Life 2",
                           stateFlags: .fullyInstalled, sizeOnDisk: 1, libraryPath: lib)
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        cfg.executableRelativePath = "hl2.exe"

        let pid = try await orchestrator.launchInBottle(
            app: app, config: cfg, backend: backend, prefix: prefix, logURL: paths.log(forAppID: 220))
        #expect(pid == 4242)

        // Graphics injected into the shared prefix.
        let injected = PrefixLayout(prefix: prefix).system32.appendingPathComponent("D3DMetal.dll")
        #expect(FileManager.default.fileExists(atPath: injected.path))

        // The detached spawn used the shared (bottle) prefix and the resolved exe.
        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.environment["WINEPREFIX"] == prefix.path)
        #expect(spawn.executable.path == "/w/wine64")
        #expect(spawn.arguments == [lib.appendingPathComponent("steamapps/common/Half-Life 2/hl2.exe").path])
    }

    @Test("Throws executableNotFound when no exe can be resolved")
    func noExecutable() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())

        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let app = SteamApp(appID: 9, name: "X", installDir: "Nope",
                           stateFlags: .fullyInstalled, sizeOnDisk: 1,
                           libraryPath: tmp.url)   // install dir doesn't exist → no exe
        await #expect(throws: LaunchOrchestrator.LaunchError.self) {
            try await orchestrator.launchInBottle(
                app: app, config: GameConfig(appID: 9), backend: backend,
                prefix: tmp.url, logURL: paths.log(forAppID: 9))
        }
    }
}

@Suite("ExecutableResolver")
struct ExecutableResolverTests {

    @Test("Auto-detects the largest exe, preferring the install-dir name")
    func autodetect() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let game = try tmp.makeDir("Game")
        try tmp.write("Game/redist/vcredist.exe", "x")             // small
        try tmp.write("Game/Game.exe", String(repeating: "B", count: 5000))  // matches dir name
        let exe = ExecutableResolver.firstExecutable(in: game)
        #expect(exe?.lastPathComponent == "Game.exe")
    }

    @Test("Returns nil when no exe exists")
    func none() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dir = try tmp.makeDir("Empty")
        #expect(ExecutableResolver.firstExecutable(in: dir) == nil)
    }
}
