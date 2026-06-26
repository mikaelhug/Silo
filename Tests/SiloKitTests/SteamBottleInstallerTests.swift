import Foundation
import Testing
@testable import SiloKit

@Suite("SteamBottleInstaller")
struct SteamBottleInstallerTests {

    @Test("Boots the bottle and runs the Steam installer silently")
    func install() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://example.com/steam-bottle/SteamSetup.exe"
        FakeURLProtocol.stub(url, data: Data("MZ-installer".utf8))

        let fake = FakeProcessRunner()
        let installer = SteamBottleInstaller(runner: fake, session: FakeURLProtocol.makeSession())
        let bottle = tmp.url.appendingPathComponent("MasterBottle")
        let wine = URL(fileURLWithPath: "/w/wine64")

        let result = try await installer.install(bottle: bottle, wine: wine, installerURL: URL(string: url)!)
        #expect(result == bottle)

        let calls = fake.invocations
        #expect(calls.count == 2)
        #expect(calls[0].arguments == ["wineboot", "--init"])
        #expect(calls[0].environment["WINEPREFIX"] == bottle.path)
        #expect(calls[0].environment["WINEDLLOVERRIDES"] == "mscoree,mshtml=")   // no mono/gecko hang
        #expect(calls[1].arguments.first?.hasSuffix("SteamSetup.exe") == true)
        #expect(calls[1].arguments.last == "/S")                       // silent install
        #expect(calls[1].environment["WINEPREFIX"] == bottle.path)
        #expect(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("SteamSetup.exe").path))
    }

    @Test("Throws wineNotConfigured without a wine binary")
    func noWine() async throws {
        let installer = SteamBottleInstaller(runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        await #expect(throws: SteamBottleInstaller.InstallError.wineNotConfigured) {
            try await installer.install(bottle: URL(fileURLWithPath: "/b"), wine: nil)
        }
    }

    @Test("Throws winebootFailed when boot fails (before any download)")
    func bootFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 5))
        let installer = SteamBottleInstaller(runner: fake, session: FakeURLProtocol.makeSession())
        await #expect(throws: SteamBottleInstaller.InstallError.winebootFailed(exitCode: 5)) {
            try await installer.install(
                bottle: tmp.url.appendingPathComponent("b"), wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }

    @Test("BackendConfig.steamWine falls back to game wine when unset")
    func steamWineFallback() {
        var cfg = BackendConfig()
        cfg.wineBinaryPath = URL(fileURLWithPath: "/gptk/wine64")
        #expect(cfg.steamWine?.path == "/gptk/wine64")
        cfg.steamWineBinaryPath = URL(fileURLWithPath: "/vanilla/wine64")
        #expect(cfg.steamWine?.path == "/vanilla/wine64")
    }
}
