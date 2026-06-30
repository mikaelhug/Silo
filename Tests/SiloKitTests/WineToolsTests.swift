import Foundation
import Testing
@testable import SiloKit

@Suite("WineTools")
struct WineToolsTests {
    let wine = URL(fileURLWithPath: "/rt/bin/wine64")
    let prefix = URL(fileURLWithPath: "/bottles/SteamBottle")
    let log = URL(fileURLWithPath: "/logs/tools.log")

    @Test("open(winecfg) spawns `wine winecfg` detached in the prefix, with msync")
    func openWinecfg() async throws {
        let runner = FakeProcessRunner()
        try await WineTools(runner: runner).open(.winecfg, prefix: prefix, wine: wine, logURL: log)
        let inv = try #require(runner.lastInvocation)
        #expect(inv.executable == wine)
        #expect(inv.arguments == ["winecfg"])
        #expect(inv.environment["WINEPREFIX"] == "/bottles/SteamBottle")
        #expect(inv.environment["WINEMSYNC"] == "1")   // attach to the bottle's wineserver, don't fork
        #expect(inv.detached)
        #expect(inv.logURL == log)
    }

    @Test("each tool maps to its wine subcommand (winecfg / regedit / control)")
    func toolNames() async throws {
        for tool in WineTools.Tool.allCases {
            let runner = FakeProcessRunner()
            try await WineTools(runner: runner).open(tool, prefix: prefix, wine: wine, logURL: log)
            #expect(runner.lastInvocation?.arguments == [tool.rawValue])
        }
        #expect(WineTools.Tool.allCases.map(\.rawValue) == ["winecfg", "regedit", "control"])
    }

    @Test("setRetinaMode(true) writes the Mac Driver RetinaMode=y key (runs to completion)")
    func retinaOn() async throws {
        let runner = FakeProcessRunner()
        try await WineTools(runner: runner).setRetinaMode(true, prefix: prefix, wine: wine)
        let inv = try #require(runner.lastInvocation)
        #expect(inv.executable == wine)
        #expect(inv.arguments == [
            "reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
            "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"])
        #expect(inv.environment["WINEPREFIX"] == "/bottles/SteamBottle")
        #expect(inv.environment["WINEMSYNC"] == "1")
        #expect(!inv.detached)   // a registry write must complete before launch
    }

    @Test("setRetinaMode(false) writes RetinaMode=n")
    func retinaOff() async throws {
        let runner = FakeProcessRunner()
        try await WineTools(runner: runner).setRetinaMode(false, prefix: prefix, wine: wine)
        let args = runner.lastInvocation?.arguments ?? []
        let d = try #require(args.firstIndex(of: "/d"))
        #expect(args[d + 1] == "n")
    }

    @Test("a failed reg add throws registryWriteFailed")
    func regAddFailure() async throws {
        let runner = FakeProcessRunner()
        runner.queueResult(ProcessResult(exitCode: 1))
        await #expect(throws: WineTools.ToolsError.registryWriteFailed(1)) {
            try await WineTools(runner: runner).setRetinaMode(true, prefix: prefix, wine: wine)
        }
    }
}
