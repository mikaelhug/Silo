import Foundation
import Testing
@testable import SiloKit

@Suite("SteamBottleInstaller")
struct SteamBottleInstallerTests {

    @Test("Boots, spawns the silent installer, waits for Steam.exe, then kills the bottle")
    func install() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://example.com/steam-bottle/SteamSetup.exe"
        FakeURLProtocol.stub(url, data: Data("MZ-installer".utf8))

        let fake = FakeProcessRunner()
        let bottle = tmp.url.appendingPathComponent("MasterBottle")
        let steamDir = DiscoveryEngine.steamRoot(inBottle: bottle)
        // Simulate the silent bootstrapper dropping Steam.exe when it's spawned.
        fake.onRun = { inv in
            if inv.arguments.first?.hasSuffix("SteamSetup.exe") == true {
                try? FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: steamDir.appendingPathComponent("steam.exe").path, contents: Data())
            }
        }
        let installer = SteamBottleInstaller(runner: fake, session: FakeURLProtocol.makeSession())
        let wine = URL(fileURLWithPath: "/w/wine64")

        let result = try await installer.install(
            bottle: bottle, wine: wine, installerURL: URL(string: url)!,
            pollTimeout: .seconds(2), pollInterval: .milliseconds(20))
        #expect(result == bottle)

        let calls = fake.invocations
        #expect(calls.count == 3)
        #expect(calls[0].arguments == ["wineboot", "--init"])           // boot
        #expect(calls[0].environment["WINEPREFIX"] == bottle.path)
        #expect(calls[0].environment["WINEDLLOVERRIDES"] == "mscoree,mshtml=")   // no mono/gecko hang
        #expect(calls[1].arguments.first?.hasSuffix("SteamSetup.exe") == true)   // installer
        #expect(calls[1].arguments.last == "/S")                       // silent install
        #expect(calls[1].detached == true)                             // spawned (it never returns)
        #expect(calls[1].environment["WINEPREFIX"] == bottle.path)
        #expect(calls[2].executable.lastPathComponent == "wineserver") // crash-loop killed
        #expect(calls[2].arguments == ["-k"])
        #expect(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("SteamSetup.exe").path))
    }

    @Test("Throws installerFailed if Steam.exe never appears (then still kills the bottle)")
    func installerTimesOut() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://example.com/steam-timeout/SteamSetup.exe"
        FakeURLProtocol.stub(url, data: Data("MZ".utf8))
        let fake = FakeProcessRunner()   // never creates Steam.exe
        let installer = SteamBottleInstaller(runner: fake, session: FakeURLProtocol.makeSession())
        let bottle = tmp.url.appendingPathComponent("MasterBottle")
        await #expect(throws: SteamBottleInstaller.InstallError.installerFailed(exitCode: -1)) {
            try await installer.install(
                bottle: bottle, wine: URL(fileURLWithPath: "/w/wine64"), installerURL: URL(string: url)!,
                pollTimeout: .milliseconds(80), pollInterval: .milliseconds(20))
        }
        #expect(fake.invocations.last?.arguments == ["-k"])   // bottle killed even on timeout
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
