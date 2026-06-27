import Foundation
import Testing
@testable import SiloKit

@Suite("ConfigStore + config models")
struct ConfigStoreTests {

    private func makeStore() throws -> (ConfigStore, AppPaths, TempDir) {
        let tmp = try TempDir()
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        return (ConfigStore(paths: paths), paths, tmp)
    }

    @Test("Loads a default state when nothing is saved")
    func defaultState() async throws {
        let (store, _, tmp) = try makeStore()
        defer { tmp.cleanup() }
        let state = await store.load()
        #expect(state.games.isEmpty)
        #expect(state.backend.detectedSource == .none)
        #expect(!state.backend.isWineConfigured)
    }

    @Test("Round-trips backend + game configs through JSON")
    func roundTrip() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }

        var backend = BackendConfig(detectedSource: .whisky)
        backend.wineBinaryPath = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        backend.masterBottlePath = URL(fileURLWithPath: "/bottles/master")
        try await store.saveBackend(backend)

        var game = GameConfig(appID: 220)
        game.backend = .crossover
        game.envFlags = EnvFlags(syncMode: .msync, metalHUD: true, dxvkHUD: "fps")
        game.presence = .emulatorStub
        game.customArgs = ["-novid", "-high"]
        try await store.saveGame(game)

        #expect(FileManager.default.fileExists(atPath: paths.configFile.path))

        let reloaded = await store.load()
        #expect(reloaded.backend.detectedSource == .whisky)
        #expect(reloaded.backend.steamRoot?.path == "/bottles/master/drive_c/Program Files (x86)/Steam")
        let g = reloaded.config(for: 220)
        #expect(g.backend == .crossover)
        #expect(g.envFlags.syncMode == .msync && g.envFlags.metalHUD)
        #expect(g.presence == .emulatorStub)
        #expect(g.customArgs == ["-novid", "-high"])
    }

    @Test("saveGame upserts rather than duplicating")
    func upsert() async throws {
        let (store, _, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try await store.saveGame(GameConfig(appID: 10))
        try await store.saveGame(GameConfig(appID: 10, backend: .crossover))
        let state = await store.load()
        #expect(state.games.count == 1)
        #expect(state.config(for: 10).backend == .crossover)
    }

    @Test("config(for:) returns a fresh default for unknown apps")
    func defaultGameConfig() {
        let state = AppState()
        let g = state.config(for: 999)
        #expect(g.appID == 999)
        #expect(g.backend == .gptk)
        #expect(g.presence == .steamAppIDFile)
        #expect(g.envFlags.syncMode == .msync)   // Apple-Silicon default
    }

    @Test("AppPaths derives prefix / log / config locations")
    func appPaths() {
        let paths = AppPaths(supportDir: URL(fileURLWithPath: "/sup/Silo"))
        #expect(paths.prefix(forAppID: 220).path == "/sup/Silo/Prefixes/220")
        #expect(paths.log(forAppID: 220).path == "/sup/Silo/Logs/220.log")
        #expect(paths.configFile.lastPathComponent == "config.json")
        #expect(paths.runtimesDir.lastPathComponent == "Runtimes")
    }

    @Test("EnvFlags produces backend-appropriate environment")
    func envFlags() {
        let flags = EnvFlags(syncMode: .msync, metalHUD: true, dxvkHUD: "fps,memory",
                             extra: ["WINEDEBUG": "+seh"])
        let gptk = flags.environment(for: .gptk)
        #expect(gptk["WINEMSYNC"] == "1")
        #expect(gptk["WINEESYNC"] == nil)              // mutually exclusive
        #expect(gptk["MTL_HUD_ENABLED"] == "1")
        #expect(gptk["DXVK_HUD"] == nil)               // DXVK HUD only for crossover
        #expect(gptk["WINEDEBUG"] == "+seh")           // extra merged

        let cx = flags.environment(for: .crossover)
        #expect(cx["DXVK_HUD"] == "fps,memory")
    }

    @Test("EnvFlags migrates legacy esync/msync configs to SyncMode")
    func migratesLegacySync() throws {
        let msyncCfg = try JSONDecoder().decode(
            EnvFlags.self, from: Data(#"{"esync": false, "msync": true, "metalHUD": true}"#.utf8))
        #expect(msyncCfg.syncMode == .msync)
        #expect(msyncCfg.metalHUD)

        let esyncCfg = try JSONDecoder().decode(
            EnvFlags.self, from: Data(#"{"esync": true, "msync": false}"#.utf8))
        #expect(esyncCfg.syncMode == .esync)
        // Legacy configs (no perf keys) get the recommended AVX default.
        #expect(esyncCfg.advertiseAVX)
    }

    @Test("EnvFlags performance vars: AVX everywhere, MetalFX/DXR only for GPTK")
    func perfFlags() {
        let on = EnvFlags(advertiseAVX: true, metalHUD: true, metalFX: true, dxr: true)
        let gptk = on.environment(for: .gptk)
        #expect(gptk["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(gptk["MTL_HUD_ENABLED"] == "1")
        #expect(gptk["D3DM_ENABLE_METALFX"] == "1")
        #expect(gptk["D3DM_SUPPORT_DXR"] == "1")

        let cx = on.environment(for: .crossover)
        #expect(cx["ROSETTA_ADVERTISE_AVX"] == "1")        // Rosetta applies on every backend
        #expect(cx["D3DM_ENABLE_METALFX"] == nil)          // D3DMetal vars are GPTK-only

        #expect(EnvFlags(advertiseAVX: false).environment(for: .gptk)["ROSETTA_ADVERTISE_AVX"] == nil)
    }

    @Test("BackendConfig wine fallback selection")
    func wineFallback() {
        var cfg = BackendConfig()
        cfg.crossoverWinePath = URL(fileURLWithPath: "/cx/wine")
        // No GPTK wine set → gptk request falls back to crossover.
        #expect(cfg.wineBinary(for: .gptk)?.path == "/cx/wine")
        cfg.wineBinaryPath = URL(fileURLWithPath: "/gptk/wine64")
        #expect(cfg.wineBinary(for: .gptk)?.path == "/gptk/wine64")
        #expect(cfg.wineBinary(for: .crossover)?.path == "/cx/wine")
    }
}
