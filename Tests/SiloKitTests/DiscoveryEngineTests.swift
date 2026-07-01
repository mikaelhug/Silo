import Foundation
import Testing
@testable import SiloKit

@Suite("DiscoveryEngine")
struct DiscoveryEngineTests {

    /// Build a temp Steam tree with the given manifests under `<root>/steamapps`.
    private func makeSteamRoot(_ tmp: TempDir, named: String, manifests: [String]) throws -> URL {
        let root = try tmp.makeDir(named)
        for fixture in manifests {
            try tmp.write("\(named)/steamapps/\(fixture)", try FixtureLoader.text(fixture))
        }
        return root
    }

    @Test("Discovers games from the primary library, sorted by name")
    func primaryLibrary() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
                                          manifests: ["appmanifest_220.acf", "appmanifest_570.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.name) == ["Dota 2", "Half-Life 2"])     // alphabetical
        #expect(apps.first(where: { $0.appID == 220 })?.libraryPath == steamRoot)
    }

    @Test("Includes additional libraries from libraryfolders.vdf")
    func additionalLibraries() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let secondRoot = try makeSteamRoot(tmp, named: "Lib2", manifests: ["appmanifest_570.acf"])

        let vdf = """
        "libraryfolders"
        {
            "0" { "path" "\(steamRoot.path)" "apps" { "220" "1" } }
            "1" { "path" "\(secondRoot.path)" "apps" { "570" "1" } }
        }
        """
        try tmp.write("Steam/steamapps/libraryfolders.vdf", vdf)

        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(Set(apps.map(\.appID)) == [220, 570])
        #expect(apps.first(where: { $0.appID == 570 })?.libraryPath.standardizedFileURL == secondRoot.standardizedFileURL)
    }

    @Test("Skips malformed manifests without failing the scan")
    func skipsMalformed() async throws {
        let tmp = try TempDir()
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
                                          manifests: ["appmanifest_220.acf", "appmanifest_malformed.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])
    }

    @Test("Throws libraryUnreadable when the primary steamapps exists but can't be listed")
    func unreadablePrimaryLibrary() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let steamRoot = try makeSteamRoot(tmp, named: "Steam", manifests: ["appmanifest_220.acf"])
        let steamapps = steamRoot.appendingPathComponent("steamapps")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: steamapps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamapps.path)
        }
        await #expect(throws: DiscoveryEngine.DiscoveryError.libraryUnreadable(steamapps)) {
            try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        }
    }

    @Test("Throws when the steamapps directory is missing")
    func missingSteamapps() async throws {
        let tmp = try TempDir()
        let steamRoot = try tmp.makeDir("EmptySteam")
        await #expect(throws: DiscoveryEngine.DiscoveryError.self) {
            try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        }
    }

    @Test("Excludes shared system packages (Steamworks Common Redistributables, LastOwner 0)")
    func excludesRedistributables() async throws {
        let tmp = try TempDir()
        // A real owned game (220) alongside the auto-installed redistributables package (228980).
        let steamRoot = try makeSteamRoot(tmp, named: "Steam",
            manifests: ["appmanifest_220.acf", "appmanifest_228980.acf"])
        let apps = try await DiscoveryEngine().discoverGames(steamRoot: steamRoot)
        #expect(apps.map(\.appID) == [220])                       // 228980 hidden — not a game
        #expect(!apps.contains { $0.name == "Steamworks Common Redistributables" })
    }
}
