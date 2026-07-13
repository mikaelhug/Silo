import Foundation
import Testing
@testable import SiloKit

@Suite("GameConfig.launchOptionsString")
struct GameConfigTests {

    @Test("Joins customArgs into a space-separated string")
    func joins() {
        var cfg = GameConfig(appID: 1, customArgs: ["-windowed", "-dx11", "-novid"])
        #expect(cfg.launchOptionsString == "-windowed -dx11 -novid")
        cfg.customArgs = []
        #expect(cfg.launchOptionsString == "")
    }

    @Test("Splits on whitespace, collapsing repeats and trimming")
    func splits() {
        var cfg = GameConfig(appID: 1)
        cfg.launchOptionsString = "  -a   -b\t-c  "
        #expect(cfg.customArgs == ["-a", "-b", "-c"])   // no empty tokens
        cfg.launchOptionsString = ""
        #expect(cfg.customArgs == [])
    }

    @Test("Round-trips through makePlan as game arguments")
    func feedsLaunchPlan() throws {
        var cfg = GameConfig(appID: 7)
        cfg.launchOptionsString = "-foo -bar"
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let exe = URL(fileURLWithPath: "/lib/g.exe")
        let plan = try LaunchOrchestrator.makePlan(
            config: cfg, backend: backend, gameExe: exe,
            prefix: URL(fileURLWithPath: "/p"), logURL: URL(fileURLWithPath: "/p.log"))
        #expect(plan.arguments == [exe.path, "-foo", "-bar"])
    }

    @Test("graphics choice round-trips; defaults to .auto; a legacy backend key is ignored")
    func graphicsCodec() throws {
        var c = GameConfig(appID: 220)
        #expect(c.graphics == .auto)                       // default
        c.graphics = .dxmt
        let back = try JSONDecoder().decode(GameConfig.self, from: JSONEncoder().encode(c))
        #expect(back.graphics == .dxmt)                    // round-trips

        // An old config.json with no graphics key → .auto; the dual-bottle-era `backend` key is ignored.
        let legacy = Data(#"{"appID":220,"backend":"dxmt"}"#.utf8)
        let decoded = try JSONDecoder().decode(GameConfig.self, from: legacy)
        #expect(decoded.appID == 220)
        #expect(decoded.graphics == .auto)
    }

    @Test("learned hint persists independently of graphics; absent → nil; nil isn't encoded")
    func learnedFieldsCodec() throws {
        var c = GameConfig(appID: 220)
        #expect(c.learnedBackend == nil && c.learnedUnderRuntime == nil)   // defaults
        c.learnedBackend = .dxmt
        c.learnedUnderRuntime = "GPTK-4.0_beta_1"
        let encoded = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(GameConfig.self, from: encoded)
        #expect(back.learnedBackend == .dxmt && back.learnedUnderRuntime == "GPTK-4.0_beta_1")

        // A nil hint is omitted from the JSON (encodeIfPresent), so an untouched config stays clean.
        let cleanJSON = String(decoding: try JSONEncoder().encode(GameConfig(appID: 1)), as: UTF8.self)
        #expect(!cleanJSON.contains("learnedBackend"))

        // The split is the whole point: `.auto` survives alongside a learned `.dxmt` — the hint is NOT the
        // user's choice. An old config with no learned keys decodes both as nil.
        let split = Data(#"{"appID":220,"graphics":"auto","learnedBackend":"dxmt","learnedUnderRuntime":"GPTK-4.0_beta_1"}"#.utf8)
        let d = try JSONDecoder().decode(GameConfig.self, from: split)
        #expect(d.graphics == .auto && d.learnedBackend == .dxmt && d.learnedUnderRuntime == "GPTK-4.0_beta_1")
        let noLearned = try JSONDecoder().decode(GameConfig.self, from: Data(#"{"appID":220}"#.utf8))
        #expect(noLearned.learnedBackend == nil && noLearned.learnedUnderRuntime == nil)
    }
}
