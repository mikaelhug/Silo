import Foundation
import Testing
@testable import SiloKit

@Suite("AppManifestDecoder")
struct AppManifestDecoderTests {
    let decoder = AppManifestDecoder()
    let lib = URL(fileURLWithPath: "/tmp/Steam")

    @Test("Decodes a fully-installed game (220)")
    func decode220() throws {
        let app = try decoder.decode(text: FixtureLoader.text("appmanifest_220.acf"), libraryPath: lib)
        #expect(app.appID == 220)
        #expect(app.name == "Half-Life 2")
        #expect(app.installDir == "Half-Life 2")
        #expect(app.isFullyInstalled)
        #expect(!app.needsUpdate)
        #expect(app.sizeOnDisk == 6_845_413_587)
        #expect(app.buildID == 6_906_421)
        #expect(app.lastUpdated == Date(timeIntervalSince1970: 1_659_899_091))
        #expect(app.downloadProgress == nil)          // BytesToDownload == 0
        #expect(app.installURL.path == "/tmp/Steam/steamapps/common/Half-Life 2")
    }

    @Test("Decodes an updating game with partial download progress (570)")
    func decode570() throws {
        let app = try decoder.decode(text: FixtureLoader.text("appmanifest_570.acf"), libraryPath: lib)
        #expect(app.appID == 570)
        #expect(app.name == "Dota 2")
        #expect(app.isFullyInstalled)                  // StateFlags 6 = fullyInstalled | updateRequired
        #expect(app.needsUpdate)
        #expect(app.downloadProgress == 0.25)          // 12.5e9 / 50e9
    }

    @Test("Throws missingRoot when AppState is absent")
    func missingRoot() {
        #expect(throws: AppManifestDecoder.DecodeError.missingRoot) {
            try decoder.decode(text: #""NotAppState" { "appid" "1" }"#, libraryPath: lib)
        }
    }

    @Test("Throws missingField when appid is absent")
    func missingField() {
        #expect(throws: AppManifestDecoder.DecodeError.missingField("appid")) {
            try decoder.decode(text: #""AppState" { "name" "X" "installdir" "x" }"#, libraryPath: lib)
        }
    }

    @Test("Throws invalidInteger on a non-numeric appid")
    func invalidInteger() {
        #expect(throws: AppManifestDecoder.DecodeError.invalidInteger(field: "appid", value: "abc")) {
            try decoder.decode(text: #""AppState" { "appid" "abc" "name" "X" "installdir" "x" }"#, libraryPath: lib)
        }
    }

    @Test("Propagates tokenizer errors for malformed manifests")
    func malformed() {
        #expect(throws: ACFTokenizer.TokenizerError.self) {
            try decoder.decode(text: FixtureLoader.text("appmanifest_malformed.acf"), libraryPath: lib)
        }
    }
}
