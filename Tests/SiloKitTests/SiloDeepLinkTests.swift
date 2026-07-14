import Foundation
import Testing
@testable import SiloKit

@Suite("SiloDeepLink")
struct SiloDeepLinkTests {

    @Test("steam link round-trips through url and back")
    func steamRoundTrip() throws {
        let link = SiloDeepLink.playSteam(appID: 440)
        #expect(link.url.absoluteString == "silo://play/steam/440")
        #expect(SiloDeepLink(url: link.url) == link)
    }

    @Test("manual link round-trips through url and back")
    func manualRoundTrip() throws {
        let id = UUID()
        let link = SiloDeepLink.playManual(id: id)
        #expect(link.url.absoluteString == "silo://play/manual/\(id.uuidString)")
        #expect(SiloDeepLink(url: link.url) == link)
    }

    @Test("manual UUID parses case-insensitively (open may lowercase the URL)")
    func manualLowercasedUUID() throws {
        let id = UUID()
        let lowered = URL(string: "silo://play/manual/\(id.uuidString.lowercased())")!
        #expect(SiloDeepLink(url: lowered) == .playManual(id: id))
    }

    @Test("scheme is matched case-insensitively")
    func schemeCaseInsensitive() {
        #expect(SiloDeepLink(url: URL(string: "SILO://play/steam/7")!) == .playSteam(appID: 7))
    }

    @Test("malformed links are rejected (fail closed)")
    func rejectsMalformed() {
        let bad = [
            "https://play/steam/440",         // wrong scheme
            "silo://open/steam/440",          // wrong host
            "silo://play/steam/notanumber",   // non-numeric appID
            "silo://play/steam",              // missing id
            "silo://play/steam/440/extra",    // too many components
            "silo://play/manual/not-a-uuid",  // malformed UUID
            "silo://play/xbox/440",           // unknown kind
            "silo://play",                    // no path
        ]
        for s in bad {
            #expect(SiloDeepLink(url: URL(string: s)!) == nil, "should reject \(s)")
        }
    }

    @Test("bundleIDComponent is unique + stable per game kind")
    func bundleIDComponent() {
        #expect(SiloDeepLink.playSteam(appID: 440).bundleIDComponent == "steam-440")
        let id = UUID()
        #expect(SiloDeepLink.playManual(id: id).bundleIDComponent == "manual-\(id.uuidString.lowercased())")
    }
}
