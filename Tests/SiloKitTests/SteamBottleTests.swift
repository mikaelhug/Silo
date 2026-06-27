import Foundation
import Testing
@testable import SiloKit

@Suite("SteamBottle")
struct SteamBottleTests {

    private func make(_ tmp: TempDir) -> (SteamBottle, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        return (bottle, fake, paths)
    }

    @Test("installSteam boots the bottle then runs the silent SteamSetup")
    func installSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, _) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))

        try await bottle.installSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        let calls = fake.invocations
        #expect(calls.contains { $0.arguments == ["wineboot", "--init"] })
        let install = try #require(calls.last)
        #expect(install.arguments.last == "/S")
        #expect(install.arguments.first?.hasSuffix("SteamSetup.exe") == true)
    }

    @Test("launchSteam runs steam.exe in a Wine virtual desktop with the CEF-render flags + msync")
    func launchSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, paths) = make(tmp)
        _ = try await bottle.launchSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments.first == "explorer")
        #expect(call.arguments.contains { $0.hasPrefix("/desktop=") })   // virtual desktop
        #expect(call.arguments.contains(paths.steamBottleExe.path))
        #expect(call.arguments.contains("-cef-disable-gpu"))
        #expect(call.environment["WINEPREFIX"] == paths.steamBottle.path)
        #expect(call.environment["WINEMSYNC"] == "1")                    // co-residency with games
        #expect(call.environment["WINEDLLOVERRIDES"]?.contains("gameoverlayrenderer") == true)
        #expect(call.environment["WINEDLLOVERRIDES"]?.contains("winebus") == true)   // SDL bus crash fix
    }

    @Test("installWebHelperWrapper preserves the real webhelper and drops the wrapper in its place")
    func webHelperWrapper() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        // The wine runtime ships the wrapper at <wineRoot>/share/silo/.
        let wine = tmp.url.appendingPathComponent("wine/bin/wine64")
        _ = try tmp.write("wine/share/silo/steamwebhelper-wrapper.exe", "WRAPPER")
        // Steam installed its real webhelper in the bottle.
        let helper = paths.steamBottleWebHelper
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "REAL".write(to: helper, atomically: true, encoding: .utf8)

        try bottle.installWebHelperWrapper(wine: wine)
        let orig = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
        #expect(try String(contentsOf: helper, encoding: .utf8) == "WRAPPER")   // wrapper in place
        #expect(try String(contentsOf: orig, encoding: .utf8) == "REAL")        // real one preserved

        // Idempotent: a second call doesn't clobber the preserved real binary.
        try bottle.installWebHelperWrapper(wine: wine)
        #expect(try String(contentsOf: orig, encoding: .utf8) == "REAL")
    }

}
