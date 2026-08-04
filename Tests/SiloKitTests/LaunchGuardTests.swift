import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("Launch guards")
struct LaunchGuardTests {

    /// A config written by a NEWER Silo (an unknown backend/sync value) must degrade, never throw — a throw
    /// propagates out of AppState and ConfigStore returns a FRESH one, wiping every runtime path, per-game
    /// setting and manual game, with the next save overwriting the file.
    @Test("an unknown enum value in config.json degrades instead of wiping the document")
    func unknownEnumValuesDoNotWipeConfig() throws {
        let json = """
        {"appID":220,"graphics":"future_backend","learnedBackend":"future_backend",
         "envFlags":{"syncMode":"future_sync","metalBackend":"future_metal"}}
        """
        let cfg = try JSONDecoder().decode(GameConfig.self, from: Data(json.utf8))
        #expect(cfg.appID == 220)                 // the document survived
        #expect(cfg.graphics == .auto)            // unknown choice → Automatic
        #expect(cfg.learnedBackend == nil)        // unknown hint → dropped
        #expect(cfg.envFlags.syncMode == .msync)  // unknown sync → the safe default
        #expect(cfg.envFlags.metalBackend == .auto)
    }

    /// Steam running is NOT Steam signed in: a client on the login screen registers its pid and holds a live
    /// wineserver, so the game would launch, fail SteamAPI_Init and vanish while the UI said "Launched".
    @Test("play refuses when the bottle's Steam has never signed in")
    func refusesWhenSteamNotSignedIn() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let bottle = SteamBottle(runner: FakeProcessRunner(), paths: paths)
        let client = paths.steamBottleClientDir
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        #expect(!bottle.isSignedIn)                                     // warmed but never signed in

        FileManager.default.createFile(
            atPath: client.appendingPathComponent("ssfn9876").path, contents: Data())
        #expect(bottle.isSignedIn)                                      // machine token ⇒ signed in

        // Fails OPEN so a filesystem hiccup can never block a launch.
        let missing = SteamBottle(runner: FakeProcessRunner(),
                                  paths: AppPaths(supportDir: tmp.url.appendingPathComponent("nope")))
        #expect(missing.isSignedIn)
    }
}
