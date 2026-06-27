import Foundation
import Testing
@testable import SiloKit

@Suite("SteamPresenceInstaller")
struct SteamPresenceInstallerTests {
    let installer = SteamPresenceInstaller()

    private func makeGame(_ tmp: TempDir) throws -> URL {
        try tmp.write("install/game.exe", "MZ")
    }

    @Test(".none makes no changes")
    func none() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let receipt = try installer.apply(strategy: .none, appID: 220, gameExe: exe)
        #expect(receipt.createdFiles.isEmpty)
    }

    @Test(".steamAppIDFile writes steam_appid.txt next to the exe")
    func appIDFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        _ = try installer.apply(strategy: .steamAppIDFile, appID: 220, gameExe: exe)
        let file = exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "220")
    }

    @Test(".sharedSteamClient symlinks a Steam client into the prefix")
    func sharedClient() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let client = try tmp.makeDir("steamClient")
        let prefix = try tmp.makeDir("prefix")

        let receipt = try installer.apply(
            strategy: .sharedSteamClient, appID: 220, gameExe: exe,
            steamClientRoot: client, prefix: prefix)

        let link = PrefixLayout(prefix: prefix).driveC
            .appendingPathComponent("Program Files (x86)/Steam")
        let isLink = try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        #expect(isLink == true)
        #expect(FileManager.default.fileExists(atPath: link.path))   // resolves to the client
        #expect(!receipt.createdFiles.isEmpty)
    }

    @Test(".sharedSteamClient throws when no Steam client is available")
    func sharedClientMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        #expect(throws: SteamPresenceInstaller.PresenceError.steamClientUnavailable) {
            try installer.apply(strategy: .sharedSteamClient, appID: 220, gameExe: exe,
                                steamClientRoot: nil, prefix: tmp.url)
        }
    }
}
