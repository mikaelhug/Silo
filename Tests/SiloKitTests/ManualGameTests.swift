import Foundation
import Testing
@testable import SiloKit

@Suite("ManualGame")
struct ManualGameTests {

    @Test("Defaults to the GPTK backend")
    func defaultsToGPTK() {
        let game = ManualGame(name: "Game", executablePath: URL(fileURLWithPath: "/g/game.exe"))
        #expect(game.backend == .gptk)
    }

    @Test("A pre-DXMT config.json (no `backend` key) decodes to GPTK instead of dropping the game")
    func tolerantDecodeOfLegacyConfig() throws {
        // Exactly the shape ManualGame had before the backend field — a missing `backend` must NOT throw
        // (which would wipe the whole manualGames array via AppState's tolerant decode).
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old Game",
         "executablePath":"file:///g/old.exe","envFlags":{},"customArgs":["-w"]}
        """
        let game = try JSONDecoder().decode(ManualGame.self, from: Data(legacy.utf8))
        #expect(game.backend == .gptk)
        #expect(game.name == "Old Game")
        #expect(game.customArgs == ["-w"])
    }

    @Test("Backend survives an encode/decode round-trip")
    func roundTripsBackend() throws {
        let game = ManualGame(name: "Old", executablePath: URL(fileURLWithPath: "/g/old.exe"), backend: .dxmt)
        let decoded = try JSONDecoder().decode(ManualGame.self, from: JSONEncoder().encode(game))
        #expect(decoded.backend == .dxmt)
        #expect(decoded == game)
    }
}
