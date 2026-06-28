import Foundation
import Testing
@testable import SiloKit

@Suite("Updater")
struct UpdaterTests {

    private let releaseJSON = """
    {
      "tag_name": "v0.2.0",
      "name": "Silo 0.2.0",
      "assets": [
        { "name": "Silo.app.zip", "browser_download_url": "https://example.com/Silo.app.zip", "size": 12345 }
      ]
    }
    """

    // Tests run in parallel and share FakeURLProtocol's registry, so each uses a UNIQUE repo URL.
    private func updater(repo: String, current: String) -> Updater {
        Updater(repo: repo, currentVersion: current, session: FakeURLProtocol.makeSession())
    }

    @Test("Reports a newer release with its download URL")
    func newer() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-newer/releases/latest",
                             data: Data(releaseJSON.utf8))
        let check = try await updater(repo: "owner/Silo-newer", current: "0.1.1").checkForUpdate()
        #expect(check.latestVersion == "0.2.0")
        #expect(check.isNewer)
        #expect(check.downloadURL?.absoluteString == "https://example.com/Silo.app.zip")
        #expect(check.releaseName == "Silo 0.2.0")
    }

    @Test("Reports no update when current >= latest")
    func notNewer() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-eq/releases/latest",
                             data: Data(releaseJSON.utf8))
        let check = try await updater(repo: "owner/Silo-eq", current: "0.2.0").checkForUpdate()
        #expect(!check.isNewer)
    }

    @Test("Throws badResponse on a non-200 status")
    func badResponse() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-404/releases/latest",
                             statusCode: 404, data: Data("{}".utf8))
        await #expect(throws: Updater.UpdateError.badResponse(404)) {
            try await updater(repo: "owner/Silo-404", current: "0.1.1").checkForUpdate()
        }
    }

    @Test("Numeric version comparison handles multi-digit components")
    func versionCompare() {
        #expect(Updater.isVersion("0.10.0", newerThan: "0.9.0"))
        #expect(Updater.isVersion("1.0.0", newerThan: "0.99.0"))
        #expect(!Updater.isVersion("0.2.0", newerThan: "0.2.0"))
        #expect(!Updater.isVersion("0.1.1", newerThan: "0.2.0"))
    }

    // MARK: - Inline apply

    @Test("downloadUpdate saves the release .zip into the target directory")
    func downloadsZip() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let asset = "https://dl.example.com/silo-dl/Silo-0.3.0.zip"
        FakeURLProtocol.stub(asset, data: Data("ZIP-BYTES".utf8))
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: asset), releaseName: "Silo 0.3.0")
        let saved = try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        #expect(saved.lastPathComponent == "Silo-0.3.0.zip")
        #expect(try Data(contentsOf: saved) == Data("ZIP-BYTES".utf8))
    }

    @Test("downloadUpdate throws when the release has no downloadable asset")
    func downloadNoAsset() async throws {
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true, downloadURL: nil, releaseName: nil)
        await #expect(throws: Updater.UpdateError.noDownloadAsset) {
            try await Updater().downloadUpdate(check, into: FileManager.default.temporaryDirectory)
        }
    }

    @Test("installUpdate unpacks the .zip and atomically replaces the installed app bundle")
    func installSwapsBundle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let runner = SystemProcessRunner()
        // A "new" Silo.app, zipped with real ditto (exactly the format the release ships).
        try tmp.write("build/Silo.app/Contents/MacOS/Silo", "NEW BINARY")
        let zip = tmp.url.appendingPathComponent("Silo.zip")
        _ = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", tmp.url.appendingPathComponent("build/Silo.app").path, zip.path],
            environment: [:], currentDirectory: nil)
        // The currently-installed (old) Silo.app gets replaced in place.
        try tmp.write("Applications/Silo.app/Contents/MacOS/Silo", "OLD BINARY")
        let installed = tmp.url.appendingPathComponent("Applications/Silo.app")

        try await Updater(runner: runner).installUpdate(zip: zip, replacing: installed)

        let binary = try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Silo"), encoding: .utf8)
        #expect(binary == "NEW BINARY")
        // Staging dir is cleaned up — no leftover `.silo-update-*` sibling.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: tmp.url.appendingPathComponent("Applications").path)
        #expect(!siblings.contains { $0.hasPrefix(".silo-update-") })
    }
}
