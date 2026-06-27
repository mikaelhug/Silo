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
        let written = try installer.apply(strategy: .none, appID: 220, gameExe: exe)
        #expect(written == nil)
        #expect(!FileManager.default.fileExists(
            atPath: exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt").path))
    }

    @Test(".steamAppIDFile writes steam_appid.txt next to the exe")
    func appIDFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let written = try installer.apply(strategy: .steamAppIDFile, appID: 220, gameExe: exe)
        let file = exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        #expect(written == file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "220")
    }
}
