import Foundation
import Testing
@testable import SiloKit

@Suite("OwnedAppsReader")
struct OwnedAppsReaderTests {

    @Test("Reads owned app ids from localconfig.vdf, unioned across accounts")
    func reads() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steam = try tmp.makeDir("Steam")
        let vdf = try FixtureLoader.text("localconfig.vdf")
        try tmp.write("Steam/userdata/111/config/localconfig.vdf", vdf)
        // A second account that adds 440 (already present) + 730.
        try tmp.write("Steam/userdata/222/config/localconfig.vdf",
                      #""UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" { "730" { } } } } } }"#)

        let ids = OwnedAppsReader().ownedAppIDs(steamRoot: steam)
        #expect(ids == [220, 440, 570, 730])
    }

    @Test("Returns empty when there is no userdata")
    func empty() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(OwnedAppsReader().ownedAppIDs(steamRoot: tmp.url).isEmpty)
    }
}

@Suite("SteamLibraryInstaller")
struct SteamLibraryInstallerTests {

    private func makeBottleWithSteam(_ tmp: TempDir) throws -> URL {
        let bottle = tmp.url.appendingPathComponent("MasterBottle")
        let steamRoot = DiscoveryEngine.steamRoot(inBottle: bottle)
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: steamRoot.appendingPathComponent("steam.exe").path,
                                       contents: Data("MZ".utf8))
        return bottle
    }

    @Test("Queues steam://install/<appid> per app with the bottle as WINEPREFIX")
    func queues() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let bottle = try makeBottleWithSteam(tmp)
        let fake = FakeProcessRunner()
        let wine = URL(fileURLWithPath: "/w/wine64")

        let count = try await SteamLibraryInstaller(runner: fake)
            .queueInstalls(appIDs: [220, 570], bottle: bottle, wine: wine)
        #expect(count == 2)
        #expect(fake.invocations.count == 2)
        #expect(fake.invocations.allSatisfy { $0.executable == wine })
        #expect(fake.invocations.allSatisfy { $0.environment["WINEPREFIX"] == bottle.path })
        #expect(fake.invocations[0].arguments.last == "steam://install/220")
        #expect(fake.invocations[1].arguments.last == "steam://install/570")
        #expect(fake.invocations[0].arguments.first?.hasSuffix("steam.exe") == true)
    }

    @Test("Throws steamNotFound when steam.exe is missing")
    func steamMissing() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let bottle = tmp.url.appendingPathComponent("EmptyBottle")
        await #expect(throws: SteamLibraryInstaller.InstallError.self) {
            try await SteamLibraryInstaller(runner: FakeProcessRunner())
                .queueInstalls(appIDs: [220], bottle: bottle, wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }

    @Test("Throws on no wine / no apps")
    func guards() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let bottle = try makeBottleWithSteam(tmp)
        await #expect(throws: SteamLibraryInstaller.InstallError.wineNotConfigured) {
            try await SteamLibraryInstaller(runner: FakeProcessRunner())
                .queueInstalls(appIDs: [220], bottle: bottle, wine: nil)
        }
        await #expect(throws: SteamLibraryInstaller.InstallError.noApps) {
            try await SteamLibraryInstaller(runner: FakeProcessRunner())
                .queueInstalls(appIDs: [], bottle: bottle, wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }
}
