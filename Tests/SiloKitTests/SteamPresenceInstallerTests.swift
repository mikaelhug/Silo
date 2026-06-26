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
        #expect(receipt.createdFiles.isEmpty && receipt.backups.isEmpty)
    }

    @Test(".steamAppIDFile writes steam_appid.txt next to the exe")
    func appIDFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        _ = try installer.apply(strategy: .steamAppIDFile, appID: 220, gameExe: exe)
        let file = exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "220")
    }

    @Test(".emulatorStub backs up the original DLL and restores it on revert")
    func emulatorStub() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let dir = exe.deletingLastPathComponent()
        // Original game DLL + the user-provided stub (same filename).
        try tmp.write("install/steam_api64.dll", "ORIGINAL")
        let stub = try tmp.write("stub/steam_api64.dll", "GOLDBERG")

        let receipt = try installer.apply(strategy: .emulatorStub, appID: 220, gameExe: exe, stubSource: stub)
        let dest = dir.appendingPathComponent("steam_api64.dll")
        #expect(try String(contentsOf: dest, encoding: .utf8) == "GOLDBERG")     // stub in place
        #expect(receipt.backups.count == 1)

        try installer.revert(receipt)
        #expect(try String(contentsOf: dest, encoding: .utf8) == "ORIGINAL")     // restored
        let appid = dir.appendingPathComponent("steam_appid.txt")
        #expect(!FileManager.default.fileExists(atPath: appid.path))             // created file removed
    }

    @Test(".emulatorStub re-apply preserves the real original DLL backup (no data loss)")
    func emulatorStubReapply() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let dir = exe.deletingLastPathComponent()
        try tmp.write("install/steam_api64.dll", "ORIGINAL")
        let stub = try tmp.write("stub/steam_api64.dll", "GOLDBERG")

        let r1 = try installer.apply(strategy: .emulatorStub, appID: 220, gameExe: exe, stubSource: stub)
        _ = try installer.apply(strategy: .emulatorStub, appID: 220, gameExe: exe, stubSource: stub)  // re-apply

        // The backup must still hold the REAL original (the bug overwrote it with the stub).
        let backup = dir.appendingPathComponent("steam_api64.dll.silo-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "ORIGINAL")
        // And the first receipt still restores the real original.
        try installer.revert(r1)
        #expect(try String(contentsOf: dir.appendingPathComponent("steam_api64.dll"), encoding: .utf8) == "ORIGINAL")
    }

    @Test(".emulatorStub without a stub path throws")
    func stubNotProvided() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        #expect(throws: SteamPresenceInstaller.PresenceError.stubNotProvided) {
            try installer.apply(strategy: .emulatorStub, appID: 220, gameExe: exe, stubSource: nil)
        }
    }

    @Test(".sharedSteamClient symlinks the master Steam into the prefix")
    func sharedClient() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        let master = try tmp.makeDir("masterSteam")
        let prefix = try tmp.makeDir("prefix")

        let receipt = try installer.apply(
            strategy: .sharedSteamClient, appID: 220, gameExe: exe,
            masterSteamRoot: master, prefix: prefix)

        let link = PrefixLayout(prefix: prefix).driveC
            .appendingPathComponent("Program Files (x86)/Steam")
        let isLink = try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        #expect(isLink == true)
        #expect(FileManager.default.fileExists(atPath: link.path))   // resolves to master
        #expect(!receipt.createdFiles.isEmpty)
    }

    @Test(".sharedSteamClient throws when the master Steam is unavailable")
    func sharedClientMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let exe = try makeGame(tmp)
        #expect(throws: SteamPresenceInstaller.PresenceError.steamClientUnavailable) {
            try installer.apply(strategy: .sharedSteamClient, appID: 220, gameExe: exe,
                                masterSteamRoot: nil, prefix: tmp.url)
        }
    }
}
