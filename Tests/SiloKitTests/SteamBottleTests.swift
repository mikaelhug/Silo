import Foundation
import Testing
@testable import SiloKit

@Suite("SteamLoginSeeder")
struct SteamLoginSeederTests {

    /// Build a fake macOS Steam data dir with a cached login.
    private func makeMacSteam(_ tmp: TempDir) throws -> URL {
        _ = try tmp.write("Steam/config/loginusers.vdf", "\"users\" { }")
        _ = try tmp.write("Steam/config/config.vdf", "cfg")
        _ = try tmp.write("Steam/registry.vdf", "reg")
        _ = try tmp.write("Steam/ssfn1234567890", "sentry")
        _ = try tmp.write("Steam/userdata/123/localconfig.vdf", "ud")
        return tmp.url.appendingPathComponent("Steam")
    }

    @Test("seeds config, registry.vdf, ssfn* and userdata into the bottle")
    func seeds() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mac = try makeMacSteam(tmp)
        let bottle = tmp.url.appendingPathComponent("BottleSteam")

        let copied = try SteamLoginSeeder().seed(from: mac, into: bottle)
        #expect(Set(copied) == ["config", "registry.vdf", "userdata", "ssfn1234567890"])
        #expect(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("config/loginusers.vdf").path))
        #expect(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("ssfn1234567890").path))
        #expect(FileManager.default.fileExists(atPath: bottle.appendingPathComponent("userdata/123/localconfig.vdf").path))
    }

    @Test("throws notLoggedIn when macOS Steam has no cached login")
    func notLoggedIn() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        _ = try tmp.makeDir("Steam")   // exists but no config/loginusers.vdf
        #expect(throws: SteamLoginSeeder.SeedError.notLoggedIn) {
            try SteamLoginSeeder().seed(from: tmp.url.appendingPathComponent("Steam"),
                                        into: tmp.url.appendingPathComponent("Bottle"))
        }
    }

    @Test("throws macSteamNotFound when macOS Steam is absent")
    func macSteamMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let mac = tmp.url.appendingPathComponent("Steam")
        #expect(throws: SteamLoginSeeder.SeedError.macSteamNotFound(mac)) {
            try SteamLoginSeeder().seed(from: mac, into: tmp.url.appendingPathComponent("Bottle"))
        }
    }
}

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

    @Test("launchSteam spawns steam.exe detached, silent, in the bottle prefix")
    func launchSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, paths) = make(tmp)
        _ = try await bottle.launchSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments == [paths.steamBottleExe.path] + SteamBottle.cefRenderArgs)
        #expect(call.arguments.contains("-cef-disable-gpu"))
        #expect(call.environment["WINEPREFIX"] == paths.steamBottle.path)
    }

    @Test("launchGame runs the exe inside the shared bottle prefix (never an isolated one)")
    func launchGame() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, paths) = make(tmp)
        let exe = URL(fileURLWithPath: "/games/HL2/hl2.exe")
        _ = try await bottle.launchGame(
            exe: exe, wine: URL(fileURLWithPath: "/w/wine64"),
            environment: ["WINEPREFIX": "/some/isolated/prefix", "DXVK_HUD": "fps"],
            logURL: paths.log(forAppID: 220))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments == [exe.path])
        #expect(call.environment["WINEPREFIX"] == paths.steamBottle.path)   // forced to the bottle
        #expect(call.environment["DXVK_HUD"] == "fps")                       // caller env preserved
    }
}
