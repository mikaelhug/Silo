import Foundation
import Testing
@testable import SiloKit

@Suite("SteamCMDClient")
struct SteamCMDClientTests {

    private func makePaths(_ tmp: TempDir) -> AppPaths {
        AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
    }

    @Test("ensureInstalled downloads + extracts SteamCMD when absent")
    func installs() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = SteamCMD.macInstallerURL.absoluteString
        FakeURLProtocol.stub(url, data: Data("tarball".utf8))
        let fake = FakeProcessRunner()
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: makePaths(tmp))

        let script = try await client.ensureInstalled()
        #expect(script.lastPathComponent == "steamcmd.sh")
        let extract = try #require(fake.invocations.last)
        #expect(extract.executable.path == "/usr/bin/tar")
        #expect(extract.arguments.first == "xzf")
        #expect(extract.arguments.contains("-C"))
    }

    @Test("ensureInstalled is a no-op when the script already exists")
    func alreadyInstalled() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        _ = try await client.ensureInstalled()
        #expect(fake.invocations.isEmpty)   // no download, no extraction
    }

    @Test("download spawns SteamCMD with the force-windows app_update for the game's bucket")
    func download() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        _ = try await client.download(appID: 220, username: "alice",
                                      logURL: tmp.url.appendingPathComponent("dl.log"))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached == true)
        #expect(call.executable.lastPathComponent == "steamcmd.sh")
        #expect(call.arguments.contains("+app_update"))
        #expect(call.arguments.contains("220"))
        #expect(call.arguments.contains("windows"))                       // forced platform
        #expect(call.arguments.contains(paths.gameInstallDir(forAppID: 220).path))
        #expect(FileManager.default.fileExists(atPath: paths.gameInstallDir(forAppID: 220).path))
    }

    @Test("ownedGames orchestrates licenses → packages → app-info, returning the full owned catalog")
    func ownedGamesCatalog() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        // Three captures in order: licenses_print, package_info_print, app_info_print.
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("License packageID 54321 :\n".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(#""54321" { "appids" { "0" "220" "1" "70" "2" "1493710" "3" "205" } }"#.utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("""
        "70"  { "common" { "name" "Half-Life" "type" "Game" "oslist" "windows,macos" } }
        "220" { "common" { "name" "Half-Life 2" "type" "Game" "oslist" "windows" } }
        "1493710" { "common" { "name" "Proton Experimental" "type" "Tool" "oslist" "windows" } }
        "205" { "common" { "oslist" "windows" } }
        """.utf8)))
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        let games = try await client.ownedGames(username: "alice")
        // The full owned catalog (sorted by name) — caching all of it lets the next refresh skip app_info.
        #expect(games.map(\.appID) == [205, 70, 220, 1493710])
        // The displayed subset (the VM's filter) keeps only real games that run on Windows.
        #expect(games.filter(\.windowsPlayable).map(\.appID) == [70, 220])
    }

    @Test("ownedGames skips app_info for already-known apps (fast warm refresh)")
    func ownedGamesUsesKnownCache() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        // Only licenses + packages are queued — NOT app_info, because both apps are already known.
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("License packageID 54321 :\n".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(#""54321" { "appids" { "0" "220" "1" "70" } }"#.utf8)))
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        let known = [
            70: SteamAppInfo(appID: 70, name: "Half-Life", oslist: ["windows"], type: "game"),
            220: SteamAppInfo(appID: 220, name: "Half-Life 2", oslist: ["windows"], type: "game"),
        ]
        let games = try await client.ownedGames(username: "alice", known: known)
        #expect(games.map(\.appID).sorted() == [70, 220])
        #expect(fake.invocations.count == 2)   // licenses + packages only — no per-app app_info
    }

    @Test("capture returns SteamCMD stdout for metadata parsing")
    func capture() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("\"oslist\" \"windows\"".utf8)))
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        let out = try await client.capture(SteamCMD.appInfoArguments(appID: 70))
        #expect(out.contains("windows"))
        #expect(fake.lastInvocation?.executable.lastPathComponent == "steamcmd.sh")
    }
}
