import Foundation
import Testing
@testable import SiloKit

@Suite("SteamPresenceStrategy Codable")
struct SteamPresenceStrategyTests {

    @Test("Unknown/removed raw values decode to .none")
    func unknownRawDecodesToNone() throws {
        for raw in ["emulatorStub", "sharedSteamClient", "xyz"] {
            let s = try JSONDecoder().decode(
                SteamPresenceStrategy.self, from: Data("\"\(raw)\"".utf8))
            #expect(s == .none)
        }
    }

    @Test("Known raw values decode correctly")
    func knownRawDecodes() throws {
        #expect(try JSONDecoder().decode(SteamPresenceStrategy.self, from: Data(#""none""#.utf8)) == .none)
        #expect(try JSONDecoder().decode(SteamPresenceStrategy.self, from: Data(#""steamAppIDFile""#.utf8)) == .steamAppIDFile)
    }

    @Test("Encode/decode round-trips both live cases")
    func roundTrips() throws {
        for strategy in [SteamPresenceStrategy.none, .steamAppIDFile] {
            let data = try JSONEncoder().encode(strategy)
            let back = try JSONDecoder().decode(SteamPresenceStrategy.self, from: data)
            #expect(back == strategy)
        }
    }

    @Test("GameConfig with a legacy/removed presence loads with presence == .none")
    func legacyGameConfigPresence() throws {
        let json = #"{"appID":42,"envFlags":{},"presence":"emulatorStub","customArgs":[]}"#
        let cfg = try JSONDecoder().decode(GameConfig.self, from: Data(json.utf8))
        #expect(cfg.presence == .none)
        #expect(cfg.appID == 42)
    }
}
