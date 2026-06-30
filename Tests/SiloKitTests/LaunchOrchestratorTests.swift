import Foundation
import Testing
@testable import SiloKit

@Suite("LaunchOrchestrator.makePlan (pure)")
struct MakePlanTests {
    let prefix = URL(fileURLWithPath: "/p/220")
    let log = URL(fileURLWithPath: "/p/220.log")
    let gameExe = URL(fileURLWithPath: "/lib/steamapps/common/Half-Life 2/hl2.exe")

    private func backend(gptk: String? = "/w/bin/wine64") -> BackendConfig {
        var b = BackendConfig()
        b.wineBinaryPath = gptk.map { URL(fileURLWithPath: $0) }
        return b
    }

    @Test("GPTK plan: bottle WINEPREFIX, sync flags, no d3d overrides without a GPTK lib dir, custom args, cwd")
    func gptkPlan() throws {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags = EnvFlags(syncMode: .msync)
        cfg.customArgs = ["-dev", "-w", "1920"]
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)

        #expect(plan.executable.path == "/w/bin/wine64")
        #expect(plan.arguments == [gameExe.path, "-dev", "-w", "1920"])
        #expect(plan.environment["WINEPREFIX"] == "/p/220")        // the shared Steam-bottle prefix
        #expect(plan.environment["WINEMSYNC"] == "1")          // MSync default on Apple Silicon
        #expect(plan.environment["WINEESYNC"] == nil)          // mutually exclusive — not both
        // GPTK injects D3DMetal; with no GPTK lib dir set here there are no d3d overrides, so
        // WINEDLLOVERRIDES is unset (the SDL crash is fixed by removing libSDL2, not a DLL override).
        #expect(plan.environment["WINEDLLOVERRIDES"] == nil)
        #expect(plan.environment["WINEDEBUG"] == Silo.wineDebug)   // build-gated (verbose local / -all CI)
        #expect(plan.currentDirectory.path == "/lib/steamapps/common/Half-Life 2")
        #expect(plan.logURL == log)
    }

    @Test("Bottle launch forces msync even if the game is configured for esync (one shared wineserver)")
    func forcesMsyncForCoResidency() throws {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags = EnvFlags(syncMode: .esync)   // user picked ESync…
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        // …but a bottle game MUST match Steam's msync or it gets its own wineserver and loses Steamworks.
        #expect(plan.environment["WINEMSYNC"] == "1")
        #expect(plan.environment["WINEESYNC"] == nil)
    }

    @Test("Bottle launch forces msync even when sync vars are injected via the extra escape hatch")
    func forcesMsyncOverExtraEscapeHatch() throws {
        var cfg = GameConfig(appID: 220)
        // Power user reaches past the SyncMode enum and injects sync vars directly via `extra`,
        // which EnvFlags.environment() merges LAST — yet co-residency must still win.
        cfg.envFlags = EnvFlags(syncMode: .msync,
                                extra: ["WINEESYNC": "1", "WINEMSYNC": "0", "MTL_HUD_ENABLED": "1"])
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        #expect(plan.environment["WINEMSYNC"] == "1")        // forced override beats extra:["WINEMSYNC":"0"]
        #expect(plan.environment["WINEESYNC"] == nil)        // forced override strips extra:["WINEESYNC":"1"]
        #expect(plan.environment["MTL_HUD_ENABLED"] == "1")  // non-sync extras still survive
    }

    @Test("GPTK plan with GPTK configured: D3DMetal resolves from the RUNTIME's lib/external, no WINEDLLPATH")
    func gptkPlanD3DMetalWiring() throws {
        let cfg = GameConfig(appID: 220)
        var b = backend()   // wine binary = /w/bin/wine64 → runtime root /w
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: b, gameExe: gameExe, prefix: prefix, logURL: log)

        // After the overlay, GPTK's libd3dshared.dylib + D3DMetal.framework live in the WINE runtime's
        // own lib/external (/w/lib/external) — that must lead the DYLD paths, ahead of the bundled deps.
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix("/w/lib/external:") == true)
        #expect(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/silo-bundled") == true)
        #expect(plan.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] == "/w/lib/external")
        // Modules live in wine's own lib/wine now (overlaid), so there is NO WINEDLLPATH; the translated
        // d3d modules are just forced to builtin so GPTK's overlaid versions win.
        #expect(plan.environment["WINEDLLPATH"] == nil)
        #expect(plan.environment["WINEDLLOVERRIDES"] == "d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
    }

    @Test("User WINEDEBUG via extra flags is preserved")
    func customWineDebug() throws {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags = EnvFlags(extra: ["WINEDEBUG": "+seh,+tid"])
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        #expect(plan.environment["WINEDEBUG"] == "+seh,+tid")
    }

    @Test("GPTK appends its d3d overrides to a user's pre-existing WINEDLLOVERRIDES (semicolon-merged, not clobbered)")
    func mergesPreExistingWineDllOverrides() throws {
        var cfg = GameConfig(appID: 220)
        // Power user forces their own DLL override via the extra escape hatch, WITH GPTK configured.
        cfg.envFlags = EnvFlags(extra: ["WINEDLLOVERRIDES": "winemenubuilder.exe=d"])
        var b = backend()
        b.gptkLibDirPath = URL(fileURLWithPath: "/g/lib/wine/x86_64-windows")
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: b, gameExe: gameExe, prefix: prefix, logURL: log)
        // GPTK's d3d overrides are APPENDED (semicolon-joined), not overwriting the user's.
        #expect(plan.environment["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d;d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,dxgi=b")
    }

    @Test("Perf env-flags (MetalHUD / MetalFX / DXR / AVX) propagate into the launch plan's environment")
    func perfFlagsPropagate() throws {
        var cfg = GameConfig(appID: 220)
        cfg.envFlags = EnvFlags(advertiseAVX: true, metalHUD: true, metalFX: true, dxr: true)
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend(), gameExe: gameExe, prefix: prefix, logURL: log)
        #expect(plan.environment["MTL_HUD_ENABLED"] == "1")
        #expect(plan.environment["D3DM_ENABLE_METALFX"] == "1")
        #expect(plan.environment["D3DM_SUPPORT_DXR"] == "1")
        #expect(plan.environment["ROSETTA_ADVERTISE_AVX"] == "1")
    }

    @Test("Throws wineNotConfigured when no wine binary is available")
    func notConfigured() {
        let cfg = GameConfig(appID: 220)
        #expect(throws: LaunchOrchestrator.LaunchError.wineNotConfigured) {
            try LaunchOrchestrator.makePlan(
                config: cfg, backend: backend(gptk: nil),
                gameExe: gameExe, prefix: prefix, logURL: log)
        }
    }

    @Test("logHeader dumps the resolved launch context (exe, args, cwd, env sorted)")
    func logHeader() throws {
        let plan = LaunchPlan(
            executable: URL(fileURLWithPath: "/rt/bin/wine64"),
            arguments: ["/g/Foo/Foo.exe", "-windowed"],
            environment: ["WINEPREFIX": "/b/Steam", "WINEMSYNC": "1", "WINEDLLOVERRIDES": "d3d11=b"],
            currentDirectory: URL(fileURLWithPath: "/g/Foo"),
            logURL: URL(fileURLWithPath: "/logs/foo.log"))
        let header = plan.logHeader(at: Date(timeIntervalSince1970: 0))
        #expect(header.contains("exe   : /rt/bin/wine64"))
        #expect(header.contains("args  : /g/Foo/Foo.exe -windowed"))
        #expect(header.contains("cwd   : /g/Foo"))
        #expect(header.contains("WINEPREFIX=/b/Steam"))
        #expect(header.contains("WINEDLLOVERRIDES=d3d11=b"))
        #expect(header.contains("begin process output"))
        // env is sorted alphabetically: WINEDLLOVERRIDES < WINEMSYNC < WINEPREFIX
        let dll = try #require(header.range(of: "WINEDLLOVERRIDES"))
        let pre = try #require(header.range(of: "WINEPREFIX"))
        #expect(dll.lowerBound < pre.lowerBound)
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

    @Test("launchManualGame spawns the absolute .exe into the bottle prefix (no Steam presence)")
    func manualGameLaunch() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let exe = try tmp.write("Games/My Game/game.exe", "MZ")
        let prefix = try tmp.makeDir("bottle")
        let game = ManualGame(name: "My Game", executablePath: exe, customArgs: ["-windowed"])

        let pid = try await orchestrator.launchManualGame(
            game, backend: backend, prefix: prefix, logURL: tmp.url.appendingPathComponent("m.log"))
        #expect(pid == 4242)

        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.executable.path == "/w/wine64")
        #expect(spawn.arguments == [exe.path, "-windowed"])         // absolute exe + custom args
        #expect(spawn.environment["WINEPREFIX"] == prefix.path)     // co-located in the shared bottle
        #expect(spawn.environment["WINEMSYNC"] == "1")
        // No steam_appid.txt next to the exe — manual games don't use Steamworks.
        #expect(!FileManager.default.fileExists(atPath: exe.deletingLastPathComponent()
            .appendingPathComponent("steam_appid.txt").path))
    }

    @Test("launchManualGame throws when the .exe is missing")
    func manualGameMissingExe() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let orchestrator = LaunchOrchestrator(runner: FakeProcessRunner(), linker: GraphicsLinker())
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let game = ManualGame(name: "Gone", executablePath: tmp.url.appendingPathComponent("nope.exe"))
        await #expect(throws: LaunchOrchestrator.LaunchError.self) {
            try await orchestrator.launchManualGame(
                game, backend: backend, prefix: tmp.url, logURL: tmp.url.appendingPathComponent("m.log"))
        }
    }

    @Test("launchInBottle rejects an executableRelativePath that climbs out of the install dir")
    func rejectsPathEscapingRelativeExe() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let orchestrator = LaunchOrchestrator(runner: FakeProcessRunner(), linker: GraphicsLinker())
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let app = SteamApp(appID: 220, name: "HL2", installDir: "HL2",
                           stateFlags: .fullyInstalled, sizeOnDisk: 1, libraryPath: tmp.url)
        var cfg = GameConfig(appID: 220)
        cfg.executableRelativePath = "../../escape.exe"           // path traversal out of the install dir
        await #expect(throws: LaunchOrchestrator.LaunchError.self) {
            try await orchestrator.launchInBottle(
                app: app, config: cfg, backend: backend, prefix: tmp.url,
                logURL: tmp.url.appendingPathComponent("x.log"))
        }
    }

    @Test("runInstaller spawns the installer .exe in the bottle prefix")
    func installerRun() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let installer = try tmp.write("setup.exe", "MZ")
        let prefix = try tmp.makeDir("bottle")

        _ = try await orchestrator.runInstaller(
            exe: installer, backend: backend, prefix: prefix, logURL: tmp.url.appendingPathComponent("i.log"))
        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.arguments == [installer.path])
        #expect(spawn.environment["WINEPREFIX"] == prefix.path)
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
