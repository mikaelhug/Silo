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

    private func backend(gptk: String? = "/w/bin/wine64", cx: String? = "/cx/wine") -> BackendConfig {
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

        #expect(plan.executable.path == "/w/bin/wine64")
        #expect(plan.arguments == [gameExe.path, "-dev", "-w", "1920"])
        #expect(plan.environment["WINEPREFIX"] == "/p/220")        // the shared Steam-bottle prefix
        #expect(plan.environment["WINEMSYNC"] == "1")          // MSync default on Apple Silicon
        #expect(plan.environment["WINEESYNC"] == nil)          // mutually exclusive — not both
        // GPTK injects D3DMetal and adds no DXVK overrides; with no GPTK lib dir set here there are no
        // d3d overrides either, so WINEDLLOVERRIDES is unset (the SDL crash is fixed by removing libSDL2,
        // not a DLL override).
        #expect(plan.environment["WINEDLLOVERRIDES"] == nil)
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

    @Test("GPTK plan with GPTK configured: D3DMetal resolves from the RUNTIME's lib/external, no WINEDLLPATH")
    func gptkPlanD3DMetalWiring() throws {
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        var b = backend()   // wine binary = /w/bin/wine64 → runtime root /w
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        let plan = try LaunchOrchestrator.makePlan(
            app: app, config: cfg, backend: b, gameExe: gameExe, prefix: prefix, logURL: log)

        // After the overlay, GPTK's libd3dshared.dylib + D3DMetal.framework live in the WINE runtime's
        // own lib/external (/w/lib/external) — that must lead the DYLD paths, ahead of the bundled deps.
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix("/w/lib/external:") == true)
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/silo-bundled") == true)
        #expect(plan.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] == "/w/lib/external")
        // Modules live in wine's own lib/wine now (overlaid), so there is NO WINEDLLPATH; the translated
        // d3d modules are just forced to builtin so GPTK's overlaid versions win.
        #expect(plan.environment["WINEDLLPATH"] == nil)
        #expect(plan.environment["WINEDLLOVERRIDES"] == "d3d10,d3d11,d3d12,dxgi=b")
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

    @Test("Overlays GPTK into the wine runtime + spawns the game detached into the shared bottle prefix")
    func fullPipeline() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())

        // A fake wine runtime + GPTK runtime, a fake install tree with the exe, and the shared bottle prefix.
        let wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        let gptkLibDir = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "D3DMETAL-PE")
        let gptkUnix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
        try FileManager.default.createSymbolicLink(
            atPath: gptkUnix.appendingPathComponent("d3d11.so").path,
            withDestinationPath: "../../external/libd3dshared.dylib")
        try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
        let lib = try tmp.makeDir("lib")
        try tmp.write("lib/steamapps/common/Half-Life 2/hl2.exe", "MZ")
        let prefix = try tmp.makeDir("bottle")

        var backend = BackendConfig()
        backend.wineBinaryPath = wine
        backend.gptkLibDirPath = gptkLibDir

        let app = SteamApp(appID: 220, name: "HL2", installDir: "Half-Life 2",
                           stateFlags: .fullyInstalled, sizeOnDisk: 1, libraryPath: lib)
        var cfg = GameConfig(appID: 220)
        cfg.backend = .gptk
        cfg.executableRelativePath = "hl2.exe"

        let pid = try await orchestrator.launchInBottle(
            app: app, config: cfg, backend: backend, prefix: prefix, logURL: paths.log(forAppID: 220))
        #expect(pid == 4242)

        // GPTK overlaid into the wine RUNTIME (not the prefix): wine now carries GPTK's d3d11.dll.
        let overlaid = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        #expect(try String(contentsOf: overlaid, encoding: .utf8) == "D3DMETAL-PE")

        // The detached spawn used the shared (bottle) prefix and the resolved exe.
        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.environment["WINEPREFIX"] == prefix.path)
        #expect(spawn.executable.path == wine.path)
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
