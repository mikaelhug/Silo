import Foundation
import Testing
@testable import SiloKit

@Suite("ManualGame")
struct ManualGameTests {

    @Test("Defaults to the Automatic graphics choice")
    func defaultsToAuto() {
        let game = ManualGame(name: "Game", executablePath: URL(fileURLWithPath: "/g/game.exe"))
        #expect(game.graphics == .auto)
    }

    @Test("A very old config (no graphics/backend key) decodes to Automatic instead of dropping the game")
    func tolerantDecodeOfLegacyConfig() throws {
        // The shape ManualGame had before any backend field — a missing key must NOT throw (which would wipe
        // the whole manualGames array via AppState's tolerant decode); it defaults to Automatic.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old Game",
         "executablePath":"file:///g/old.exe","envFlags":{},"customArgs":["-w"]}
        """
        let game = try JSONDecoder().decode(ManualGame.self, from: Data(legacy.utf8))
        #expect(game.graphics == .auto)
        #expect(game.name == "Old Game")
        #expect(game.customArgs == ["-w"])
    }

    @Test("A pre-Automatic config migrates its explicit `backend` to the matching explicit choice")
    func migratesLegacyExplicitBackend() throws {
        // Games added between DXMT support and Automatic support wrote a concrete `backend` string. Those were
        // explicit user pins, so they migrate to the explicit choice — NOT silently to Automatic.
        for (raw, expected): (String, GraphicsChoice) in [("gptk", .gptk), ("dxmt", .dxmt)] {
            let json = """
            {"id":"\(UUID().uuidString)","name":"G","executablePath":"file:///g/g.exe",
             "envFlags":{},"backend":"\(raw)","customArgs":[]}
            """
            let game = try JSONDecoder().decode(ManualGame.self, from: Data(json.utf8))
            #expect(game.graphics == expected)
        }
    }

    @Test("A config without a bottleID adopts its own id as the bottle (pre-shared-bottle migration)")
    func migratesMissingBottleID() throws {
        let gid = UUID()
        let legacy = """
        {"id":"\(gid.uuidString)","name":"Solo","executablePath":"file:///g/solo.exe","envFlags":{},
         "graphics":"auto","customArgs":[]}
        """
        let game = try JSONDecoder().decode(ManualGame.self, from: Data(legacy.utf8))
        #expect(game.bottleID == gid)                // owns its own bottle, exactly as before
        #expect(game.workingDirectory == nil)
    }

    @Test("A shared bottleID and working directory round-trip through encode/decode")
    func roundTripsBottleAndWorkingDir() throws {
        let bottle = UUID()
        let game = ManualGame(
            bottleID: bottle, name: "Sibling", executablePath: URL(fileURLWithPath: "/g/bin/app.exe"),
            workingDirectory: URL(fileURLWithPath: "/g/bin"), customArgs: ["-x"])
        #expect(game.bottleID == bottle)
        #expect(game.id != bottle)                   // distinct library identity, shared bottle
        let decoded = try JSONDecoder().decode(ManualGame.self, from: JSONEncoder().encode(game))
        #expect(decoded == game)
        #expect(decoded.workingDirectory?.path == "/g/bin")
    }

    @Test("An unknown/newer graphics value degrades to Automatic instead of throwing (forward-compat)")
    func tolerantDecodeOfUnknownGraphics() throws {
        // A config written by a FUTURE Silo (e.g. a `d9mt` choice) opened by this build must not throw — a
        // throw would drop the whole config document, not just this game.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Future","executablePath":"file:///g/f.exe",
         "envFlags":{},"graphics":"d9mt","customArgs":[]}
        """
        let game = try JSONDecoder().decode(ManualGame.self, from: Data(json.utf8))
        #expect(game.graphics == .auto)
    }

    @Test("The graphics choice survives an encode/decode round-trip (and writes `graphics`, not `backend`)")
    func roundTripsGraphics() throws {
        let game = ManualGame(name: "Old", executablePath: URL(fileURLWithPath: "/g/old.exe"), graphics: .dxmt)
        let data = try JSONEncoder().encode(game)
        let decoded = try JSONDecoder().decode(ManualGame.self, from: data)
        #expect(decoded.graphics == .dxmt)
        #expect(decoded == game)
        // New configs use the `graphics` key exclusively — the legacy `backend` key is never written back.
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"graphics\""))
        #expect(!json.contains("\"backend\""))
    }
}
