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

    @Test("install remembers a hardening failure (lastHardeningIssue) and clears it on a clean install")
    func installSurfacesHardeningIssue() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        FakeURLProtocol.stub("https://e.com/wine-q.tar.xz", data: Data("ARCHIVE".utf8))
        FakeURLProtocol.stub("https://e.com/wine-ok.tar.xz", data: Data("ARCHIVE".utf8))
        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())

        fake.queueResult(ProcessResult(exitCode: 0))   // tar
        fake.queueResult(ProcessResult(exitCode: 1))   // xattr → quarantine NOT cleared
        try await manager.install(name: "Wine-Q", from: URL(string: "https://e.com/wine-q.tar.xz")!)
        let issue = try #require(await manager.lastHardeningIssue)
        #expect(issue.contains("quarantine") && issue.contains("Wine-Q"))

        try await manager.install(name: "Wine-OK", from: URL(string: "https://e.com/wine-ok.tar.xz")!)
        #expect(await manager.lastHardeningIssue == nil)   // clean pass resets the warning
    }

    @Test("stripBundledSDL removes libSDL2 across lib/ but prunes the lib/wine PE tree")
    func stripsSDL() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let rt = try tmp.makeDir("wine-cx")
        for f in ["libSDL2-2.0.0.dylib", "libSDL2.dylib", "libfreetype.6.dylib"] {
            try tmp.write("wine-cx/lib/silo-bundled/\(f)", "x")
        }
        try tmp.write("wine-cx/lib/libSDL2.dylib", "x")                    // custom-repo layout (top-level lib)
        try tmp.write("wine-cx/lib/wine/x86_64-unix/libSDL2.dylib", "x")   // inside the PE tree — pruned, kept

        let removed = RuntimeManager.stripBundledSDL(in: rt)
        #expect(removed == 3)                                             // 2 in silo-bundled + 1 top-level lib
        let bundled = rt.appendingPathComponent("lib/silo-bundled")
        #expect(!FileManager.default.fileExists(atPath: bundled.appendingPathComponent("libSDL2.dylib").path))
        #expect(!FileManager.default.fileExists(atPath: rt.appendingPathComponent("lib/libSDL2.dylib").path))
        #expect(FileManager.default.fileExists(atPath: bundled.appendingPathComponent("libfreetype.6.dylib").path))
        // The lib/wine subtree is pruned (not walked) — a stray dylib there is left alone + cheaply skipped.
        #expect(FileManager.default.fileExists(atPath: rt.appendingPathComponent("lib/wine/x86_64-unix/libSDL2.dylib").path))
        #expect(RuntimeManager.stripBundledSDL(in: rt) == 0)              // idempotent
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
        // Downloaded wine is de-quarantined (the load-bearing step) but NEVER re-signed — an x86_64
        // runtime runs unsigned, and codesign can't sign a non-bundle tree anyway.
        #expect(fake.invocations.contains { $0.executable.lastPathComponent == "xattr" && $0.arguments.contains("com.apple.quarantine") })
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "codesign" })
    }

    @Test("locateDXMTLibDir finds the x86_64-windows module dir by its d3d11+winemetal signature")
    func locateDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.makeDir("rt/lib/wine/x86_64-windows")
        try tmp.write("rt/lib/wine/x86_64-windows/d3d11.dll", "x")
        try tmp.write("rt/lib/wine/x86_64-windows/winemetal.dll", "x")
        let found = RuntimeManager.locateDXMTLibDir(in: tmp.url.appendingPathComponent("rt"))
        #expect(found?.lastPathComponent == "x86_64-windows")   // exact-URL compare trips on /var→/private/var
        #expect(found?.path.hasSuffix("/rt/lib/wine/x86_64-windows") == true)
        // A tree without the winemetal marker → nil (so a Wine runtime never masquerades as DXMT).
        #expect(RuntimeManager.locateDXMTLibDir(in: try tmp.makeDir("empty")) == nil)
    }

    @Test("installDXMT downloads + extracts via the SHARED engine and locates the x86_64-windows module dir")
    func installDXMT() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://e.com/dxmt.tar.xz"
        FakeURLProtocol.stub(url, data: Data("ARCHIVE".utf8))
        let fake = FakeProcessRunner()
        // Simulate tar extracting a DXMT tree (lib/wine/{x86_64-windows,x86_64-unix}).
        fake.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let dest = URL(fileURLWithPath: inv.arguments[i + 1])
                let win = dest.appendingPathComponent("lib/wine/x86_64-windows")
                let unix = dest.appendingPathComponent("lib/wine/x86_64-unix")
                try? FileManager.default.createDirectory(at: win, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
                for f in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
                    FileManager.default.createFile(atPath: win.appendingPathComponent(f).path, contents: Data("x".utf8))
                }
                FileManager.default.createFile(atPath: unix.appendingPathComponent("winemetal.so").path, contents: Data("x".utf8))
            }
        }
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        let dxmt = try await manager.installDXMT(name: "dxmt-v0.72", from: URL(string: url)!)
        #expect(dxmt.libDir?.lastPathComponent == "x86_64-windows")
        #expect(dxmt.isUsable)
        #expect(await manager.installedDXMT().map(\.name) == ["dxmt-v0.72"])
        // winemetal.so is de-quarantined (same hardening the engine gives Wine) but never re-signed.
        #expect(fake.invocations.contains { $0.executable.lastPathComponent == "xattr" && $0.arguments.contains("com.apple.quarantine") })
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "codesign" })
    }

    @Test("matchedDXMTRelease prefers the DXMT built against the configured wine, else the newest")
    func matchDXMT() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Releases newest-first (as GitHub returns them): two DXMT builds (per-wine tags) + a wine + an app tag.
        let releases = try decoder.decode([GitHubRelease].self, from: Data("""
        [{"tag_name":"dxmt-v0.72-cx26.3.0","assets":[]},
         {"tag_name":"wine-cx-26.3.0","assets":[]},
         {"tag_name":"dxmt-v0.72-cx26.2.0","assets":[]},
         {"tag_name":"v0.2.1","assets":[]}]
        """.utf8))
        // Installed wine 26.2.0 → the DXMT built against it, NOT the newest.
        #expect(RuntimeManager.matchedDXMTRelease(releases, forWine: "wine-cx-26.2.0")?.tagName == "dxmt-v0.72-cx26.2.0")
        // No matching cx → newest dxmt-*.
        #expect(RuntimeManager.matchedDXMTRelease(releases, forWine: "wine-cx-99.9.9")?.tagName == "dxmt-v0.72-cx26.3.0")
        // No wine configured → newest dxmt-*.
        #expect(RuntimeManager.matchedDXMTRelease(releases, forWine: nil)?.tagName == "dxmt-v0.72-cx26.3.0")
        // No DXMT published at all → nil.
        let noDXMT = try decoder.decode([GitHubRelease].self,
            from: Data(#"[{"tag_name":"wine-cx-26.3.0","assets":[]}]"#.utf8))
        #expect(RuntimeManager.matchedDXMTRelease(noDXMT, forWine: "wine-cx-26.3.0") == nil)
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

    @Test("safeRuntimeComponent accepts a flat tag and rejects path-traversal attempts")
    func safeRuntimeComponent() {
        // Accepts a normal release tag.
        #expect(RuntimeManager.safeRuntimeComponent("wine-cx-26.2.0") == "wine-cx-26.2.0")
        // Rejects anything that could escape the Runtimes dir.
        #expect(RuntimeManager.safeRuntimeComponent("../x") == nil)
        #expect(RuntimeManager.safeRuntimeComponent("a/b") == nil)
        #expect(RuntimeManager.safeRuntimeComponent("..") == nil)
        #expect(RuntimeManager.safeRuntimeComponent(".") == nil)
        #expect(RuntimeManager.safeRuntimeComponent("") == nil)
        #expect(RuntimeManager.safeRuntimeComponent("a\0b") == "ab")   // NUL stripped, still flat
        #expect(RuntimeManager.safeRuntimeComponent("/etc/passwd") == nil)
    }

    @Test("install rejects a path-traversal release name before any download")
    func installRejectsUnsafeName() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        await #expect(throws: RuntimeManager.RuntimeError.unsafeRuntimeName("../../evil")) {
            try await manager.install(name: "../../evil", from: URL(string: "https://e.com/x.tar.gz")!)
        }
        // Never even attempted the download/extract.
        #expect(fake.invocations.isEmpty)
    }

    @Test("install rejects a non-https download URL before any network call")
    func installRejectsInsecureURL() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        await #expect(throws: DownloadError.insecureURL("http")) {
            try await manager.install(name: "X", from: URL(string: "http://e.com/x.tar.gz")!)
        }
        #expect(fake.invocations.isEmpty)
    }

    @Test("requireDigest makes a missing .sha256 fail closed (built-in repo)")
    func requireDigestFailsClosed() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://e.com/require-digest/wine.tar.xz"
        FakeURLProtocol.stub(url, data: Data("ARCHIVE".utf8))   // NO sibling .sha256 published
        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        // requireDigest:true → checksumUnavailable; nothing extracted.
        await #expect(throws: RuntimeManager.RuntimeError.checksumUnavailable) {
            try await manager.installWine(name: "WineReq", from: URL(string: url)!, requireDigest: true)
        }
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "tar" })
        // requireDigest:false (a user override) keeps the legacy best-effort skip → installs fine.
        let fake2 = FakeProcessRunner()
        fake2.onRun = { inv in
            if inv.executable.lastPathComponent == "tar",
               let i = inv.arguments.firstIndex(of: "-C"), i + 1 < inv.arguments.count {
                let bin = URL(fileURLWithPath: inv.arguments[i + 1]).appendingPathComponent("bin")
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: bin.appendingPathComponent("wine64").path, contents: Data("x".utf8))
            }
        }
        let url2 = "https://e.com/no-digest/wine.tar.xz"
        FakeURLProtocol.stub(url2, data: Data("ARCHIVE".utf8))
        let manager2 = makeManager(tmp, fake2, session: FakeURLProtocol.makeSession())
        _ = try await manager2.installWine(name: "WineOpt", from: URL(string: url2)!, requireDigest: false)
        #expect(await manager2.installedWines().map(\.name) == ["WineOpt"])
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

    @Test("both listings exclude a DXMT variant CLONE (it carries a wine binary AND the DXMT modules)")
    func listingsExcludeVariantClone() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A real base wine build.
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0/bin/wine64", "x")
        // A real DXMT extract (its own release).
        try tmp.write("Silo/Runtimes/dxmt-v0.72-cx26.2.0/lib/wine/x86_64-windows/d3d11.dll", "x")
        try tmp.write("Silo/Runtimes/dxmt-v0.72-cx26.2.0/lib/wine/x86_64-windows/winemetal.dll", "x")
        // The DXMT variant clone of the base: has BOTH a wine binary and the overlaid DXMT modules.
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0-dxmt/bin/wine64", "x")
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0-dxmt/lib/wine/x86_64-windows/d3d11.dll", "x")
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0-dxmt/lib/wine/x86_64-windows/winemetal.dll", "x")
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        // The clone appears in NEITHER list; only the genuine installs do.
        #expect(await manager.installedWines().map(\.name) == ["wine-cx-26.2.0"])
        #expect(await manager.installedDXMT().map(\.name) == ["dxmt-v0.72-cx26.2.0"])
    }

    @Test("remove cascades to the base's DXMT variant clone; a no-clone remove is a no-op there")
    func removeCascadesToClone() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0/bin/wine64", "x")
        try tmp.write("Silo/Runtimes/wine-cx-26.2.0-dxmt/bin/wine64", "x")
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        try await manager.remove(name: "wine-cx-26.2.0")
        let runtimes = tmp.url.appendingPathComponent("Silo/Runtimes")
        #expect(!FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("wine-cx-26.2.0").path))
        #expect(!FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("wine-cx-26.2.0-dxmt").path))
        // Removing a name that never had a clone doesn't throw.
        try await manager.remove(name: "wine-cx-26.2.0")
    }

    @Test("install throws downloadFailed on a non-2xx download, never invoking tar")
    func downloadFailed() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let url = "https://example.com/wine.tar.gz"
        FakeURLProtocol.stub(url, statusCode: 503, data: Data())   // empty error body, like a 503
        let fake = FakeProcessRunner()
        let manager = makeManager(tmp, fake, session: FakeURLProtocol.makeSession())
        await #expect(throws: RuntimeManager.RuntimeError.downloadFailed(503)) {
            try await manager.install(name: "X", from: URL(string: url)!)
        }
        // Early-exit before move/extract: tar never ran, no archive and no runtime dir left behind.
        #expect(!fake.invocations.contains { $0.executable.lastPathComponent == "tar" })
        let runtimes = tmp.url.appendingPathComponent("Silo/Runtimes")
        #expect(!FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("X.archive").path))
        #expect(!FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("X").path))
    }

    @Test("availableReleases throws badResponse on a non-200 (GitHub rate-limit)")
    func badResponse() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // A realistic GitHub 403 rate-limit JSON body — must NOT be decoded as [GitHubRelease].
        // Unique repo (the registry is shared across the parallel suite; `acme/wine` is taken by releases()).
        FakeURLProtocol.stub("https://api.github.com/repos/acme/wine-ratelimited/releases?per_page=3",
                             statusCode: 403, data: Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        let manager = makeManager(tmp, FakeProcessRunner(), session: FakeURLProtocol.makeSession())
        await #expect(throws: RuntimeManager.RuntimeError.badResponse(403)) {
            try await manager.availableReleases(repo: "acme/wine-ratelimited", limit: 3)
        }
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
