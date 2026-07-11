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
}
