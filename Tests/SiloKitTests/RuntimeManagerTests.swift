import Foundation
import Testing
@testable import SiloKit

@Suite("RuntimeManager")
struct RuntimeManagerTests {

    private func makeManager(_ tmp: TempDir, _ fake: FakeProcessRunner, session: URLSession) -> RuntimeManager {
        RuntimeManager(paths: AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")),
                       runner: fake, session: session)
    }

    @Test("Lists installed runtimes from the Runtimes dir")
    func installed() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.makeDir("Silo/Runtimes/GPTK-2.1/bin")
        try tmp.makeDir("Silo/Runtimes/CrossOver-24/bin")
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        let runtimes = await manager.installedRuntimes()
        #expect(runtimes.map(\.name) == ["CrossOver-24", "GPTK-2.1"])   // sorted
    }

    @Test("Fetches available assets from a release")
    func available() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let json = """
        { "tag_name":"GPTK-2.1","name":"GPTK 2.1","assets":[
          {"name":"gptk-2.1.tar.gz","browser_download_url":"https://example.com/gptk.tar.gz","size":999}]}
        """
        FakeURLProtocol.stub("https://api.github.com/repos/acme/gptk/releases/latest", data: Data(json.utf8))
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        let assets = try await manager.availableAssets(repo: "acme/gptk")
        #expect(assets.count == 1)
        #expect(assets[0].name == "gptk-2.1.tar.gz")
        #expect(assets[0].browserDownloadUrl.absoluteString == "https://example.com/gptk.tar.gz")
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

        let runtime = try await manager.install(name: "GPTK-Test", from: URL(string: downloadURL)!)
        #expect(runtime.name == "GPTK-Test")
        #expect(FileManager.default.fileExists(atPath: runtime.wineBinary.path))

        // tar was invoked with extract flags into the runtime dir.
        let tarCall = try #require(fake.invocations.first { $0.executable.lastPathComponent == "tar" })
        #expect(tarCall.arguments.contains("-xf"))

        // Archive is cleaned up; installed list now includes the runtime.
        #expect(!FileManager.default.fileExists(atPath: runtimesDir.appendingPathComponent("GPTK-Test.archive").path))
        #expect(await manager.installedRuntimes().map(\.name) == ["GPTK-Test"])

        try await manager.remove(name: "GPTK-Test")
        #expect(await manager.installedRuntimes().isEmpty)
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
    }
}
