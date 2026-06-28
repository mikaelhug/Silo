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
        try await store.saveBackend(backend)

        var game = GameConfig(appID: 220)
        game.envFlags = EnvFlags(syncMode: .msync, metalHUD: true)
        game.presence = .none
        game.customArgs = ["-novid", "-high"]
        try await store.saveGame(game)

        #expect(FileManager.default.fileExists(atPath: paths.configFile.path))

        let reloaded = await store.load()
        #expect(reloaded.backend.detectedSource == .whisky)
        #expect(reloaded.backend.wineBinaryPath?.path == "/runtimes/gptk/bin/wine64")
        let g = reloaded.config(for: 220)
        #expect(g.envFlags.syncMode == .msync && g.envFlags.metalHUD)
        #expect(g.presence == .none)
        #expect(g.customArgs == ["-novid", "-high"])
    }

    @Test("saveGame upserts rather than duplicating")
    func upsert() async throws {
        let (store, _, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try await store.saveGame(GameConfig(appID: 10))
        try await store.saveGame(GameConfig(appID: 10, presence: .none))
        let state = await store.load()
        #expect(state.games.count == 1)
        #expect(state.config(for: 10).presence == .none)
    }

    @Test("config(for:) returns a fresh default for unknown apps")
    func defaultGameConfig() {
        let state = AppState()
        let g = state.config(for: 999)
        #expect(g.appID == 999)
        #expect(g.presence == .steamAppIDFile)
        #expect(g.envFlags.syncMode == .msync)   // Apple-Silicon default
    }

    @Test("AppPaths derives log / config / bottle locations")
    func appPaths() {
        let paths = AppPaths(supportDir: URL(fileURLWithPath: "/sup/Silo"))
        #expect(paths.log(forAppID: 220).path == "/sup/Silo/Logs/220.log")
        #expect(paths.configFile.lastPathComponent == "config.json")
        #expect(paths.runtimesDir.lastPathComponent == "Runtimes")
        #expect(paths.steamBottleExe.path.hasSuffix("/SteamBottle/drive_c/Program Files (x86)/Steam/steam.exe"))
    }

    @Test("EnvFlags produces the launch environment")
    func envFlags() {
        let flags = EnvFlags(syncMode: .msync, metalHUD: true, extra: ["WINEDEBUG": "+seh"])
        let env = flags.environment()
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)              // mutually exclusive
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["WINEDEBUG"] == "+seh")           // extra merged
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

    @Test("EnvFlags performance vars: AVX + MetalFX/DXR when their flags are on")
    func perfFlags() {
        let on = EnvFlags(advertiseAVX: true, metalHUD: true, metalFX: true, dxr: true).environment()
        #expect(on["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(on["MTL_HUD_ENABLED"] == "1")
        #expect(on["D3DM_ENABLE_METALFX"] == "1")
        #expect(on["D3DM_SUPPORT_DXR"] == "1")

        let off = EnvFlags(advertiseAVX: false, metalFX: false, dxr: false).environment()
        #expect(off["ROSETTA_ADVERTISE_AVX"] == nil)
        #expect(off["D3DM_ENABLE_METALFX"] == nil)
        #expect(off["D3DM_SUPPORT_DXR"] == nil)
    }
}
