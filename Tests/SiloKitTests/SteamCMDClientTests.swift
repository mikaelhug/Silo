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

    @Test("ownedWindowsGames orchestrates licenses → packages → app-info, keeping Windows-only games")
    func ownedWindowsGames() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = makePaths(tmp)
        try FileManager.default.createDirectory(at: paths.steamCMDDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamCMDScript.path, contents: Data())
        let fake = FakeProcessRunner()
        // Three captures in order: licenses_print, package_info_print, app_info_print.
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("License packageID 54321 :\n".utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data(#""54321" { "appids" { "0" "220" "1" "70" } }"#.utf8)))
        fake.queueResult(ProcessResult(exitCode: 0, standardOutput: Data("""
        "70"  { "common" { "name" "Half-Life" "type" "Game" "oslist" "windows,macos" } }
        "220" { "common" { "name" "Half-Life 2" "type" "Game" "oslist" "windows" } }
        """.utf8)))
        let client = SteamCMDClient(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)

        let games = try await client.ownedWindowsGames(username: "alice")
        #expect(games.map(\.appID) == [220])          // 70 has a mac build → excluded; only HL2 kept
        #expect(games.first?.name == "Half-Life 2")
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
