import Foundation
import Testing
@testable import SiloKit

@Suite("WineTools")
struct WineToolsTests {
    let wine = URL(fileURLWithPath: "/rt/bin/wine64")
    let prefix = URL(fileURLWithPath: "/bottles/SteamBottle")

    @Test("setRetinaMode(true) writes RetinaMode=y AND LogPixels=192, both to completion")
    func retinaOn() async throws {
        let runner = FakeProcessRunner()
        try await WineTools(runner: runner).setRetinaMode(true, prefix: prefix, wine: wine)
        let calls = runner.invocations
        #expect(calls.count == 2)   // High Resolution Mode = RetinaMode + its DPI companion

        let retina = try #require(calls.first)
        #expect(retina.executable == wine)
        #expect(retina.arguments == [
            "reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
            "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"])
        #expect(retina.environment["WINEPREFIX"] == "/bottles/SteamBottle")
        #expect(retina.environment["WINEMSYNC"] == "1")
        #expect(!retina.detached)   // a registry write must complete before launch

        let dpi = try #require(calls.last)
        #expect(dpi.arguments == [
            "reg", "add", #"HKCU\Control Panel\Desktop"#,
            "/v", "LogPixels", "/t", "REG_DWORD", "/d", "192", "/f"])
        #expect(!dpi.detached)
    }

    @Test("setRetinaMode(false) writes RetinaMode=n AND LogPixels=96 (Wine defaults)")
    func retinaOff() async throws {
        let runner = FakeProcessRunner()
        try await WineTools(runner: runner).setRetinaMode(false, prefix: prefix, wine: wine)
        let calls = runner.invocations
        #expect(calls.count == 2)

        let a0 = calls[0].arguments
        #expect(a0.contains("RetinaMode"))
        let d0 = try #require(a0.firstIndex(of: "/d"))
        #expect(a0[d0 + 1] == "n")

        let a1 = calls[1].arguments
        #expect(a1.contains("LogPixels"))
        let d1 = try #require(a1.firstIndex(of: "/d"))
        #expect(a1[d1 + 1] == "96")
    }

    @Test("a failed reg add (the RetinaMode write) throws registryWriteFailed before the DPI write")
    func regAddFailure() async throws {
        let runner = FakeProcessRunner()
        runner.queueResult(ProcessResult(exitCode: 1))
        await #expect(throws: WineTools.ToolsError.registryWriteFailed(1)) {
            try await WineTools(runner: runner).setRetinaMode(true, prefix: prefix, wine: wine)
        }
        #expect(runner.invocations.count == 1)   // stopped after the first (failed) write
    }
}
