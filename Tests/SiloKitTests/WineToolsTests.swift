import Foundation
import Testing
@testable import SiloKit

@Suite("WineTools")
struct WineToolsTests {
    let wine = URL(fileURLWithPath: "/rt/bin/wine64")
    let prefix = URL(fileURLWithPath: "/bottles/SteamBottle")

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
