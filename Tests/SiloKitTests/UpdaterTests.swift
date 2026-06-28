import Foundation
import CryptoKit
import Testing
@testable import SiloKit

@Suite("Updater")
struct UpdaterTests {

    /// A releases LIST (the repo also hosts `wine-cx-*` runtime builds, so the updater must filter to the
    /// app's own `v*` releases). The newest entry is a Wine build — picking 0.2.0 over it proves the filter.
    private let releasesJSON = """
    [
      { "tag_name": "wine-cx-26.2.0", "name": "Wine 26.2.0", "assets": [] },
      { "tag_name": "v0.2.0", "name": "Silo 0.2.0", "assets": [
          { "name": "Silo.app.zip", "browser_download_url": "https://example.com/Silo.app.zip", "size": 12345 } ] }
    ]
    """

    // Tests run in parallel and share FakeURLProtocol's registry, so each uses a UNIQUE repo URL.
    private func updater(repo: String, current: String) -> Updater {
        Updater(repo: repo, currentVersion: current, session: FakeURLProtocol.makeSession())
    }

    @Test("Reports the newest APP release (ignoring wine-cx-* runtime releases) with its download URL")
    func newer() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-newer/releases?per_page=30",
                             data: Data(releasesJSON.utf8))
        let check = try await updater(repo: "owner/Silo-newer", current: "0.1.1").checkForUpdate()
        #expect(check.latestVersion == "0.2.0")        // NOT 26.2.0 — the wine-cx release is filtered out
        #expect(check.isNewer)
        #expect(check.downloadURL?.absoluteString == "https://example.com/Silo.app.zip")
        #expect(check.releaseName == "Silo 0.2.0")
    }

    @Test("Reports no update when current >= the newest app release")
    func notNewer() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-eq/releases?per_page=30",
                             data: Data(releasesJSON.utf8))
        let check = try await updater(repo: "owner/Silo-eq", current: "0.2.0").checkForUpdate()
        #expect(!check.isNewer)
    }

    @Test("Reports no update when only wine-cx-* releases exist (no app release at all)")
    func onlyWineReleases() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-wineonly/releases?per_page=30",
                             data: Data("""
                             [ { "tag_name": "wine-cx-26.2.0", "name": "Wine 26.2.0", "assets": [] } ]
                             """.utf8))
        let check = try await updater(repo: "owner/Silo-wineonly", current: "0.1.1").checkForUpdate()
        #expect(!check.isNewer)
        #expect(check.downloadURL == nil)
    }

    @Test("Throws badResponse on a non-200 status")
    func badResponse() async throws {
        FakeURLProtocol.stub("https://api.github.com/repos/owner/Silo-404/releases?per_page=30",
                             statusCode: 404, data: Data("[]".utf8))
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

    /// Lower-case hex SHA-256 (matches `FileDigest`).
    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("downloadUpdate saves the release .zip when its published SHA-256 matches")
    func downloadsZip() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let asset = "https://dl.example.com/silo-dl/Silo-0.3.0.zip"
        let bytes = Data("ZIP-BYTES".utf8)
        FakeURLProtocol.stub(asset, data: bytes)
        // shasum format ("<hex>  filename"); the parser takes the first whitespace-delimited token.
        FakeURLProtocol.stub(asset + ".sha256", data: Data("\(hex(bytes))  Silo-0.3.0.zip\n".utf8))
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: asset), releaseName: "Silo 0.3.0")
        let saved = try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        #expect(saved.lastPathComponent == "Silo-0.3.0.zip")
        #expect(try Data(contentsOf: saved) == bytes)
    }

    @Test("downloadUpdate throws checksumMismatch on a wrong SHA-256 and leaves no file")
    func downloadChecksumMismatch() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let asset = "https://dl.example.com/silo-dl-bad/Silo-0.3.0.zip"
        FakeURLProtocol.stub(asset, data: Data("ZIP-BYTES".utf8))
        FakeURLProtocol.stub(asset + ".sha256", data: Data("deadbeef  Silo-0.3.0.zip\n".utf8))
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: asset), releaseName: "Silo 0.3.0")
        await #expect(throws: Updater.UpdateError.checksumMismatch) {
            try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        }
        // The bad (unverified) zip must be deleted — never leave an unverified app on disk.
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("Silo-0.3.0.zip").path))
    }

    @Test("downloadUpdate throws checksumUnavailable when the .sha256 can't be fetched (404)")
    func downloadChecksumUnavailable() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let asset = "https://dl.example.com/silo-dl-nosha/Silo-0.3.0.zip"
        FakeURLProtocol.stub(asset, data: Data("ZIP-BYTES".utf8))
        FakeURLProtocol.stub(asset + ".sha256", statusCode: 404, data: Data("Not Found".utf8))
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: asset), releaseName: "Silo 0.3.0")
        await #expect(throws: Updater.UpdateError.checksumUnavailable) {
            try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        }
        // Fail-closed: no zip left behind either.
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("Silo-0.3.0.zip").path))
    }

    @Test("downloadUpdate rejects a non-https asset URL before any network call")
    func downloadInsecureURL() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: "http://dl.example.com/Silo.zip"),
                                        releaseName: "Silo 0.3.0")
        await #expect(throws: DownloadError.insecureURL("http")) {
            try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        }
    }

    @Test("downloadUpdate throws when the release has no downloadable asset")
    func downloadNoAsset() async throws {
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true, downloadURL: nil, releaseName: nil)
        await #expect(throws: Updater.UpdateError.noDownloadAsset) {
            try await Updater().downloadUpdate(check, into: FileManager.default.temporaryDirectory)
        }
    }

    @Test("downloadUpdate throws badResponse on a non-2xx asset response and writes no file")
    func downloadBadResponse() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let asset = "https://dl.example.com/silo-dl-500/Silo-0.3.0.zip"   // unique URL (shared registry)
        FakeURLProtocol.stub(asset, statusCode: 500, data: Data("oops".utf8))
        let check = Updater.UpdateCheck(latestVersion: "0.3.0", isNewer: true,
                                        downloadURL: URL(string: asset), releaseName: "Silo 0.3.0")
        await #expect(throws: Updater.UpdateError.badResponse(500)) {
            try await Updater(session: FakeURLProtocol.makeSession()).downloadUpdate(check, into: tmp.url)
        }
        // The move only runs after the guard, so the destination .zip must not exist.
        let dest = tmp.url.appendingPathComponent("Silo-0.3.0.zip")
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("installUpdate throws unpackFailed when ditto exits non-zero")
    func installUnpackDittoFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1, standardError: Data("ditto: bad".utf8)))
        let zip = tmp.url.appendingPathComponent("Silo.zip")   // ditto is faked; need not be a real zip
        try tmp.write("Applications/Silo.app/Contents/MacOS/Silo", "OLD")
        let installed = tmp.url.appendingPathComponent("Applications/Silo.app")
        await #expect(throws: Updater.UpdateError.unpackFailed) {
            try await Updater(runner: fake).installUpdate(zip: zip, replacing: installed)
        }
    }

    @Test("installUpdate throws unpackFailed and cleans up staging when archive has no .app")
    func installUnpackNoApp() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let runner = SystemProcessRunner()
        // Zip a plain file (not a .app) with real ditto.
        try tmp.write("payload/notes.txt", "hello")
        let zip = tmp.url.appendingPathComponent("NoApp.zip")
        _ = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", tmp.url.appendingPathComponent("payload").path, zip.path],
            environment: [:], currentDirectory: nil)
        try tmp.write("Applications/Silo.app/Contents/MacOS/Silo", "OLD")
        let installed = tmp.url.appendingPathComponent("Applications/Silo.app")
        await #expect(throws: Updater.UpdateError.unpackFailed) {
            try await Updater(runner: runner).installUpdate(zip: zip, replacing: installed)
        }
        // defer cleanup ran: no leftover .silo-update-* sibling in Applications/.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: tmp.url.appendingPathComponent("Applications").path)
        #expect(!siblings.contains { $0.hasPrefix(".silo-update-") })
        // Old bundle untouched (not half-replaced).
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Silo"), encoding: .utf8) == "OLD")
    }

    @Test("installUpdate throws replaceFailed when the atomic swap cannot complete")
    func installReplaceFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fm = FileManager.default
        // A real installed bundle whose parent dir we make read-only AFTER ditto stages the new .app,
        // so the unpack guard passes (New.app exists) but the atomic replaceItemAt into the parent fails.
        try tmp.write("Applications/Silo.app/Contents/MacOS/Silo", "OLD")
        let installed = tmp.url.appendingPathComponent("Applications/Silo.app")
        let parent = installed.deletingLastPathComponent()
        // Always restore write perms so TempDir cleanup can remove the tree.
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        let fake = FakeProcessRunner()   // defaultResult exitCode 0 → ditto "succeeds"
        fake.onRun = { inv in
            guard inv.executable.lastPathComponent == "ditto", inv.arguments.count >= 4 else { return }
            let staging = URL(fileURLWithPath: inv.arguments[3])   // the sibling staging dir
            let app = staging.appendingPathComponent("New.app/Contents/MacOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try? "NEW".write(to: app.appendingPathComponent("Silo"), atomically: true, encoding: .utf8)
            // Now make the parent read-only: staging + New.app exist, but the swap into parent will fail.
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        }
        let zip = tmp.url.appendingPathComponent("Silo.zip")
        await #expect(throws: Updater.UpdateError.replaceFailed) {
            try await Updater(runner: fake).installUpdate(zip: zip, replacing: installed)
        }
        // The old bundle was not half-replaced.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/Silo"), encoding: .utf8) == "OLD")
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
