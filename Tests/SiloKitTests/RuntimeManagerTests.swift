import Foundation
import CryptoKit
import Testing
@testable import SiloKit

@Suite("RuntimeManager")
struct RuntimeManagerTests {

    private func makeManager(_ tmp: TempDir, _ fake: FakeProcessRunner, session: URLSession) -> RuntimeManager {
        RuntimeManager(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")),
                       runner: fake, session: session)
    }

    @Test("Downloads and extracts a runtime via tar")
    func install() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let downloadURL = "https://example.com/gptk.tar.gz"
        FakeURLProtocol.stub(downloadURL, data: Data("FAKE-ARCHIVE-BYTES".utf8))

        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        let runtimesDir = tmp.url.appendingPathComponent("Silo/Runtimes")
        // Simulate tar extracting a wine binary into the destination.
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let destIdx = inv.arguments.firstIndex(of: "-C"), destIdx + 1 < inv.arguments.count {
                let dest = URL(fileURLWithPath: inv.arguments[destIdx + 1])
                try? FileManager.default.createDirectory(
                    at: dest.appendingPathComponent("bin"), withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: dest.appendingPathComponent("bin/wine64").path, contents: Data("x".utf8))
            }
        }

        try await manager.install(name: "GPTK-Test", from: URL(string: downloadURL)!)

        // tar was invoked with extract flags into the runtime dir.
        let tarCall = try #require(fake.invocations.first { $0.executable.lastPathComponent == "tar" })
        #expect(tarCall.arguments.contains("-xf"))

        // Archive is cleaned up; the extracted runtime (with its wine binary) is now listed.
        #expect(!FileManager.default.fileExists(atPath: runtimesDir.appendingPathComponent("GPTK-Test.archive").path))
        let wines = await manager.installedWines()
        #expect(wines.map(\.name) == ["GPTK-Test"])
        #expect(FileManager.default.fileExists(atPath: wines.first?.wineBinary?.path ?? ""))

        try await manager.remove(name: "GPTK-Test")
        #expect(await manager.installedWines().isEmpty)
    }

    @Test("Lists the latest N releases and picks the archive asset")
    func releases() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        [
          {"tag_name":"Game-Porting-Toolkit-3.0-3","name":"GPTK 3.0-3","assets":[
            {"name":"game-porting-toolkit-3.0-3.tar.xz","browser_download_url":"https://e.com/3.tar.xz","size":239200808}]},
          {"tag_name":"Game-Porting-Toolkit-3.0-2","name":"GPTK 3.0-2","assets":[
            {"name":"game-porting-toolkit-3.0-2.tar.xz","browser_download_url":"https://e.com/2.tar.xz","size":260757848}]}
        ]
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/wine/releases?per_page=3", data: Data(json.utf8))
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        let releases = try await manager.availableReleases(repo: "acme/wine", limit: 3)
        #expect(releases.map(\.tagName) == ["Game-Porting-Toolkit-3.0-3", "Game-Porting-Toolkit-3.0-2"])
        #expect(RuntimeManager.preferredAsset(releases[0])?.name == "game-porting-toolkit-3.0-3.tar.xz")
    }

    @Test("installWine downloads, extracts, and locates the wine binary")
    func installWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://e.com/wine.tar.xz"
        FakeURLProtocol.stub(url, data: Data("ARCHIVE".utf8))
        let fake = FakeProcessRunner()
        // Simulate tar extracting a nested wine tree with a top-level dir.
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let dest = URL(fileURLWithPath: inv.arguments[i + 1])
                let bin = dest.appendingPathComponent("wine-build/bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
            }
        }
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        let wine = try await manager.installWine(name: "Wine-Test", from: URL(string: url)!)
        #expect(wine.wineBinary?.lastPathComponent == "wine64")
        #expect(wine.isUsable)
        #expect(await manager.installedWines().map(\.name) == ["Wine-Test"])
        // Downloaded wine is de-quarantined + ad-hoc re-signed so Gatekeeper allows it.
        #expect(fake.invocations.contains { $0.executable.lastPathComponent == "xattr" && $0.arguments.contains("com.apple.quarantine") })
        #expect(fake.invocations.contains { $0.executable.lastPathComponent == "codesign" })
    }

    @Test("installWine verifies a published SHA-256 and rejects a mismatch")
    func checksum() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let archiveBytes = Data("ARCHIVE-BYTES".utf8)
        let good = SHA256.hash(data: archiveBytes).map { String(format: "%02x", $0) }.joined()

        // Matching digest → install succeeds.
        let okURL = "https://e.com/ok/wine.tar.xz"
        FakeURLProtocol.stub(okURL, data: archiveBytes)
        FakeURLProtocol.stub(okURL + ".sha256", data: Data("\(good)  wine.tar.xz\n".utf8))
        let fakeOK = FakeProcessRunner()
        fakeOK.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let bin = URL(fileURLWithPath: inv.arguments[i + 1]).appendingPathComponent("bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
            }
        }
        let mgrOK = makeManager(tmp, fakeOK, session: FakeURLProtocol.makeSession())
        _ = try await mgrOK.installWine(name: "WineOK", from: URL(string: okURL)!)
        #expect(await mgrOK.installedWines().map(\.name) == ["WineOK"])

        // Wrong digest → checksumMismatch, nothing extracted.
        let badURL = "https://e.com/bad/wine.tar.xz"
        FakeURLProtocol.stub(badURL, data: archiveBytes)
        FakeURLProtocol.stub(badURL + ".sha256", data: Data("deadbeef  wine.tar.xz\n".utf8))
        let mgrBad = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        await #expect(throws: RuntimeManager.RuntimeError.self) {
            try await mgrBad.installWine(name: "WineBad", from: URL(string: badURL)!)
        }
    }

    @Test("locateWineBinary prefers wine64 under a bin directory")
    func locate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("r/wine-build/bin/wine64", "x")
        try tmp.write("r/other/wine", "x")
        let found = RuntimeManager.locateWineBinary(in: tmp.url.appendingPathComponent("r"))
        #expect(found?.lastPathComponent == "wine64")
        #expect(found?.deletingLastPathComponent().lastPathComponent == "bin")
    }

    @Test("locateWineBinary ignores a directory named wine (GPTK lib/wine)")
    func locateIgnoresDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // GPTK-like: only a lib/wine DIRECTORY, no wine binary → must not be treated as Wine.
        try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        #expect(RuntimeManager.locateWineBinary(in: tmp.url.appendingPathComponent("gptk")) == nil)
        // Real wine has a bin/wine FILE alongside its lib/wine dir.
        try tmp.write("wine/bin/wine", "x")
        try tmp.makeDir("wine/lib/wine")
        #expect(RuntimeManager.locateWineBinary(in: tmp.url.appendingPathComponent("wine"))?.lastPathComponent == "wine")
    }

    @Test("installedWines excludes GPTK installs (no wine binary, just lib/wine dir)")
    func installedWinesExcludesGPTK() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.makeDir("Silo/Runtimes/GPTK-4.0/lib/wine/x86_64-windows")
        try tmp.makeDir("Silo/Runtimes/GPTK-4.0/lib/external/D3DMetal.framework")
        try tmp.write("Silo/Runtimes/Wine-1/bin/wine64", "x")
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        #expect(await manager.installedWines().map(\.name) == ["Wine-1"])
    }

    @Test("Throws extractionFailed when tar fails")
    func extractionFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        FakeURLProtocol.stub("https://example.com/bad.tar.gz", data: Data("x".utf8))
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 2, standardError: Data("tar: bad".utf8)))
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        await #expect(throws: RuntimeManager.RuntimeError.extractionFailed(2)) {
            try await manager.install(name: "Bad", from: URL(string: "https://example.com/bad.tar.gz")!)
        }
        // No half-extracted runtime left behind.
        let dest = tmp.url.appendingPathComponent("Silo/Runtimes/Bad")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
