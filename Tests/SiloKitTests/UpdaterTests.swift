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
        let check = try await updater(repo: "owner/Silo-newer", current: "0.1.0").checkForUpdate()
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
            try await updater(repo: "owner/Silo-404", current: "0.1.0").checkForUpdate()
        }
    }

    @Test("Numeric version comparison handles multi-digit components")
    func versionCompare() {
        #expect(Updater.isVersion("0.10.0", newerThan: "0.9.0"))
        #expect(Updater.isVersion("1.0.0", newerThan: "0.99.0"))
        #expect(!Updater.isVersion("0.2.0", newerThan: "0.2.0"))
        #expect(!Updater.isVersion("0.1.0", newerThan: "0.2.0"))
    }
}
