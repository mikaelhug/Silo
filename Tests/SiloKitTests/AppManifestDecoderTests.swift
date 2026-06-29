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
        #expect(app.sizeOnDisk == 6_845_413_587)
        #expect(app.buildID == 6_906_421)
        #expect(app.lastUpdated == Date(timeIntervalSince1970: 1_659_899_091))
        #expect(app.installURL.path == "/tmp/Steam/steamapps/common/Half-Life 2")
    }

    @Test("Decodes an updating game (570)")
    func decode570() throws {
        let app = try decoder.decode(text: FixtureLoader.text("appmanifest_570.acf"), libraryPath: lib)
        #expect(app.appID == 570)
        #expect(app.name == "Dota 2")
        #expect(app.isFullyInstalled)                  // StateFlags 6 = fullyInstalled | updateRequired
    }

    @Test("Reads LastOwner: a user game is owned, redistributables are shared (owner 0)")
    func lastOwnerDistinguishesGames() throws {
        let game = try decoder.decode(text: FixtureLoader.text("appmanifest_220.acf"), libraryPath: lib)
        #expect(game.lastOwner == 76561197960287930)
        #expect(!game.isSharedSystemApp)               // a real, user-owned game

        let redist = try decoder.decode(text: FixtureLoader.text("appmanifest_228980.acf"), libraryPath: lib)
        #expect(redist.lastOwner == 0)
        #expect(redist.isSharedSystemApp)              // Steamworks Common Redistributables — not a game
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

    @Test("Rejects a path-escaping installdir as a decode failure")
    func invalidInstallDir() {
        // A hostile manifest could point installdir outside steamapps/common (where the exe +
        // steam_appid.txt resolve). Each of these must be a decode failure (the manifest is skipped).
        for bad in ["../../etc", "a/b", ".", "..", ""] {
            #expect(throws: AppManifestDecoder.DecodeError.invalidInstallDir(bad)) {
                try decoder.decode(
                    text: #""AppState" { "appid" "1" "name" "X" "installdir" "\#(bad)" }"#, libraryPath: lib)
            }
        }
        // The backslash case is built directly (the ACF tokenizer would consume `\` as an escape).
        let nodeWithBackslash = KVNode.object([
            KVPair("AppState", .object([
                KVPair("appid", .leaf("1")), KVPair("name", .leaf("X")),
                KVPair("installdir", .leaf("a\\b")),
            ])),
        ])
        #expect(throws: AppManifestDecoder.DecodeError.invalidInstallDir("a\\b")) {
            try decoder.decode(nodeWithBackslash, libraryPath: lib)
        }
        // A normal flat dir name still decodes.
        let ok = try? decoder.decode(
            text: #""AppState" { "appid" "1" "name" "X" "installdir" "Half-Life 2" }"#, libraryPath: lib)
        #expect(ok?.installDir == "Half-Life 2")
    }

    @Test("Propagates tokenizer errors for malformed manifests")
    func malformed() {
        #expect(throws: ACFTokenizer.TokenizerError.self) {
            try decoder.decode(text: FixtureLoader.text("appmanifest_malformed.acf"), libraryPath: lib)
        }
    }

    @Test("LastUpdated of 0 / non-positive / non-numeric / absent yields nil lastUpdated")
    func lastUpdatedNilBranches() throws {
        func app(_ lu: String?) throws -> SteamApp {
            let lastUpdatedKV = lu.map { #""LastUpdated" "\#($0)""# } ?? ""
            let text = #""AppState" { "appid" "1" "name" "X" "installdir" "x" \#(lastUpdatedKV) }"#
            return try decoder.decode(text: text, libraryPath: lib)
        }
        #expect(try app("0").lastUpdated == nil)          // queued-but-never-updated → 'never', not 1 Jan 1970
        #expect(try app("-5").lastUpdated == nil)         // non-positive guard
        #expect(try app("notanumber").lastUpdated == nil) // TimeInterval(string) parse failure
        #expect(try app(nil).lastUpdated == nil)          // key absent entirely
        // Positive control: a real epoch still parses.
        #expect(try app("1659899091").lastUpdated == Date(timeIntervalSince1970: 1_659_899_091))
    }

    @Test("Missing StateFlags falls back to rawValue 0 and is not fully installed")
    func missingStateFlags() throws {
        let app = try decoder.decode(text: #""AppState" { "appid" "1" "name" "X" "installdir" "x" }"#, libraryPath: lib)
        #expect(app.stateFlags == StateFlags(rawValue: 0))
        #expect(!app.isFullyInstalled)
    }

    @Test("Downloading + fullyInstalled bits → contains(.downloading) and isFullyInstalled")
    func downloadingButInstalled() throws {
        // 1048580 = downloading (1048576) | fullyInstalled (4)
        let app = try decoder.decode(text: #""AppState" { "appid" "1" "name" "X" "installdir" "x" "StateFlags" "1048580" }"#, libraryPath: lib)
        #expect(app.stateFlags.contains(.downloading))
        #expect(app.isFullyInstalled)
    }

    @Test("StateFlags without the fullyInstalled bit is not fully installed")
    func notFullyInstalled() throws {
        // 2 = updateRequired only (no fullyInstalled bit)
        let app = try decoder.decode(text: #""AppState" { "appid" "1" "name" "X" "installdir" "x" "StateFlags" "2" }"#, libraryPath: lib)
        #expect(app.stateFlags.contains(.updateRequired))
        #expect(!app.isFullyInstalled)
    }
}
