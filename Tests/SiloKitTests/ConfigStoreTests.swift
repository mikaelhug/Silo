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
        #expect(!state.backend.isWineConfigured)
    }

    @Test("load() returns a fresh default for a present-but-corrupt config.json")
    func corruptFileDefault() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: paths.configFile)
        let state = await store.load()
        #expect(state.games.isEmpty)
        #expect(!state.backend.isWineConfigured)
    }

    @Test("load() returns a fresh default when config.json is valid JSON of the wrong shape")
    func wrongShapeDefault() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: paths.configFile)
        let state = await store.load()
        #expect(state.games.isEmpty)
        #expect(!state.backend.isWineConfigured)
    }

    // MARK: - .bak recovery (a corrupt config.json must never wipe all state)

    @Test("save refreshes a .bak recovery copy alongside the primary")
    func saveWritesBackup() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        try await store.saveBackend(backend)

        let bak = paths.configFile.appendingPathExtension("bak")
        let restored = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: bak))
        #expect(restored.backend.wineBinaryPath?.path == "/runtimes/gptk/bin/wine64")
    }

    @Test("load() restores the last good save from .bak when the primary is corrupt, and self-heals it")
    func corruptPrimaryRestoresFromBackup() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        try await store.saveBackend(backend)
        try await store.saveGame(GameConfig(appID: 220))

        try Data("{ torn write".utf8).write(to: paths.configFile)   // corrupt the primary only

        let state = await store.load()
        #expect(state.backend.wineBinaryPath?.path == "/runtimes/gptk/bin/wine64")
        #expect(state.games.map(\.appID) == [220])

        // The primary was healed from the backup: it decodes again on its own.
        let healed = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: paths.configFile))
        #expect(healed.games.map(\.appID) == [220])
    }

    @Test("the .bak tracks the LATEST save (a restore never resurrects stale state)")
    func backupTracksLatestSave() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try await store.saveGame(GameConfig(appID: 10))
        try await store.saveGame(GameConfig(appID: 20))

        try Data("{bad".utf8).write(to: paths.configFile)

        let state = await store.load()
        #expect(state.games.map(\.appID).sorted() == [10, 20])
    }

    @Test("corrupt primary + corrupt .bak still degrades to a fresh default, not a crash")
    func corruptPrimaryAndBackupDefaults() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try Data("{bad".utf8).write(to: paths.configFile)
        try Data("also bad".utf8).write(to: paths.configFile.appendingPathExtension("bak"))
        let state = await store.load()
        #expect(state.games.isEmpty)
        #expect(!state.backend.isWineConfigured)
    }

    @Test("a MISSING primary stays a fresh default even when a .bak exists (deleting config.json = reset)")
    func missingPrimaryIgnoresBackup() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try await store.saveGame(GameConfig(appID: 220))          // writes primary + bak
        try FileManager.default.removeItem(at: paths.configFile)  // user resets by deleting
        let state = await store.load()
        #expect(state.games.isEmpty)                              // NOT restored from bak
    }

    @Test("a corrupt config.json is recoverable by the next save")
    func corruptFileRecoverable() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try Data("{bad".utf8).write(to: paths.configFile)
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        try await store.saveBackend(backend)             // load() inside must not throw on the corrupt file
        let reloaded = await store.load()
        #expect(reloaded.backend.wineBinaryPath?.path == "/runtimes/gptk/bin/wine64")
    }

    @Test("Round-trips backend + game configs through JSON")
    func roundTrip() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }

        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/runtimes/gptk/bin/wine64")
        try await store.saveBackend(backend)

        var game = GameConfig(appID: 220)
        game.envFlags = EnvFlags(syncMode: .msync, metalHUD: true)
        game.presence = .none
        game.customArgs = ["-novid", "-high"]
        try await store.saveGame(game)

        #expect(FileManager.default.fileExists(atPath: paths.configFile.path))

        let reloaded = await store.load()
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

    @Test("updateGame field-scoped mutation preserves the rest of the config")
    func updateGameNoClobber() async throws {
        let (store, _, tmp) = try makeStore()
        defer { tmp.cleanup() }
        var game = GameConfig(appID: 440)
        game.customArgs = ["-novid", "-high"]
        try await store.saveGame(game)

        let stamp = Date()
        try await store.updateGame(appID: 440) { $0.lastPlayed = stamp }

        let reloaded = await store.load().config(for: 440)
        #expect(reloaded.customArgs == ["-novid", "-high"])
        #expect(reloaded.lastPlayed == stamp)
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

    @Test("EnvFlags legacy migration defaults to .msync when neither sync bool is set")
    func legacySyncFallsBackToMsync() throws {
        // Explicit false/false: third arm of the migration ternary.
        let both = try JSONDecoder().decode(
            EnvFlags.self, from: Data(#"{"esync": false, "msync": false}"#.utf8))
        #expect(both.syncMode == .msync)            // NOT .none — must keep a sync primitive

        // Empty legacy object: no sync keys at all → else branch, both default false.
        let empty = try JSONDecoder().decode(EnvFlags.self, from: Data(#"{}"#.utf8))
        #expect(empty.syncMode == .msync)
        #expect(empty.advertiseAVX)                 // Apple-Silicon default preserved
        #expect(!empty.metalHUD)
        #expect(empty.extra.isEmpty)

        // Prove it did not degrade to .none: WINEMSYNC set, WINEESYNC unset.
        let env = empty.environment()
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == nil)
    }

    @Test("EnvFlags survives a full encode→decode round-trip with populated extra")
    func envFlagsCodableRoundTrip() throws {
        let original = EnvFlags(
            syncMode: .esync, advertiseAVX: false, metalHUD: true,
            metalFX: true, dxr: true,
            extra: ["WINEDEBUG": "+seh", "CUSTOM_VAR": "1"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EnvFlags.self, from: data)
        #expect(decoded == original)   // Hashable/Equatable: proves extra + all fields survive
    }

    @Test("EnvFlags new syncMode key wins over stale legacy esync/msync keys")
    func envFlagsSyncModeBeatsLegacyKeys() throws {
        // Both the new key AND a contradictory legacy key present: new must win, legacy ignored.
        let decoded = try JSONDecoder().decode(
            EnvFlags.self,
            from: Data(#"{"syncMode":"esync","msync":true,"esync":false,"extra":{}}"#.utf8))
        #expect(decoded.syncMode == .esync)   // .esync is non-default → not a fallback coincidence
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

    @Test("BackendConfig tolerates a pre-retinaMode document (defaults false, never wipes config)")
    func backendConfigTolerantDecode() throws {
        // An old config.json predating retinaMode — must decode (not throw), keeping its fields.
        let old = try JSONDecoder().decode(
            BackendConfig.self,
            from: Data(#"{"wineRuntimeName":"wine-cx-26.2.0","gptkRuntimeName":"GPTK-4.0_beta_1"}"#.utf8))
        #expect(old.wineRuntimeName == "wine-cx-26.2.0")
        #expect(old.gptkRuntimeName == "GPTK-4.0_beta_1")
        #expect(!old.retinaMode)   // absent → false, not a decode error
        #expect(try JSONDecoder().decode(BackendConfig.self, from: Data("{}".utf8)).retinaMode == false)
    }

    @Test("BackendConfig round-trips retinaMode")
    func backendConfigRoundTrip() throws {
        let original = BackendConfig(retinaMode: true)
        let decoded = try JSONDecoder().decode(BackendConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.retinaMode)
    }


    // MARK: - Manual (non-Steam) games

    @Test("Round-trips manual games through JSON; upsert matches on id")
    func manualGameRoundTrip() async throws {
        let (store, _, tmp) = try makeStore()
        defer { tmp.cleanup() }
        let id = UUID()
        var game = ManualGame(id: id, name: "MyGame",
                              executablePath: URL(fileURLWithPath: "/games/MyGame/game.exe"))
        game.customArgs = ["-windowed"]
        game.envFlags.metalHUD = true
        try await store.saveManualGame(game)

        var reloaded = await store.load()
        #expect(reloaded.manualGames.count == 1)
        #expect(reloaded.manualGames.first?.name == "MyGame")
        #expect(reloaded.manualGames.first?.customArgs == ["-windowed"])
        #expect(reloaded.manualGames.first?.envFlags.metalHUD == true)

        // Re-save the same id → upsert (rename), not a duplicate.
        try await store.updateManualGame(id: id) { $0.name = "Renamed" }
        reloaded = await store.load()
        #expect(reloaded.manualGames.count == 1)
        #expect(reloaded.manualGames.first?.name == "Renamed")

        try await store.removeManualGame(id: id)
        #expect(await store.load().manualGames.isEmpty)
    }

    @Test("Old config.json (no manualGames key) still decodes, preserving backend + games")
    func backwardCompatDecode() async throws {
        let (store, paths, tmp) = try makeStore()
        defer { tmp.cleanup() }
        // Build a realistic document with the real encoder, then strip the manualGames key to simulate a
        // pre-manualGames config.json. It must NOT be discarded (that would wipe the user's config).
        var backend = BackendConfig(); backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let original = AppState(backend: backend, games: [GameConfig(appID: 220)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "manualGames")
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: paths.configFile)

        let state = await store.load()
        #expect(state.backend.wineBinaryPath?.path == "/w/wine64")   // preserved, not reset
        #expect(state.games.map(\.appID) == [220])                   // preserved
        #expect(state.manualGames.isEmpty)                           // defaulted, not a decode failure
    }
}
