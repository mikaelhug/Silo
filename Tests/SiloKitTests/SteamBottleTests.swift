import Foundation
import Testing
import CryptoKit
@testable import SiloKit

@Suite("SteamBottle")
struct SteamBottleTests {

    private func make(_ tmp: TempDir) -> (SteamBottle, FakeProcessRunner, AppPaths) {
        let (bottle, fake, paths, _) = make(tmp, session: FakeURLProtocol.makeSession())
        return (bottle, fake, paths)
    }

    /// Lower-case hex SHA-256 of `data` (to pin a stub download's digest in the verification test).
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Variant that exposes the session, so a test can register a session-scoped stub for the fixed
    /// `Silo.steamInstallerURL` without colliding with other tests stubbing the same URL. Digest maps default
    /// to `[:]` — the install-flow tests use stub bytes that can't match the real pins, so they skip
    /// verification (a missing key = unpinned = allowed); the dedicated verification test injects real digests.
    private func make(_ tmp: TempDir, session: URLSession,
                      coreFontDigests: [String: String] = [:],
                      d3dCabDigests: [String: String] = [:])
        -> (SteamBottle, FakeProcessRunner, AppPaths, URLSession) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: session, paths: paths,
                                 coreFontDigests: coreFontDigests, d3dCabDigests: d3dCabDigests)
        return (bottle, fake, paths, session)
    }

    @Test("installSteam boots the bottle then runs the silent SteamSetup")
    func installSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, _) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))

        try await bottle.installSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        let calls = fake.invocations
        #expect(calls.contains { $0.arguments == ["wineboot", "--init"] })
        let install = try #require(calls.last)
        #expect(install.arguments.last == "/S")
        #expect(install.arguments.first?.hasSuffix("SteamSetup.exe") == true)
    }

    @Test("launchSteam runs steam.exe in a Wine virtual desktop with the software-GL CEF flags + env")
    func launchSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, paths) = make(tmp)
        _ = try await bottle.launchSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        // Launched via the generated Steam.app wrapper so the Dock tile reads "Steam", not "wine"…
        #expect(call.executable.path.hasSuffix("DockApps/Steam.app/Contents/MacOS/Steam"))
        #expect(call.environment["WINELOADER"] == "/w/wine64")            // …real loader pinned for self-location
        #expect(call.arguments.first == "explorer")                       // virtual desktop (CEF presents)
        #expect(call.arguments.contains { $0.hasPrefix("/desktop=") })
        #expect(call.arguments.contains(paths.steamBottleExe.path))
        #expect(call.arguments.contains("-cef-in-process-gpu"))           // NOT --single-process
        #expect(call.environment["WINEPREFIX"] == paths.steamBottle.path)
        #expect(call.environment["WINEMSYNC"] == "1")                     // co-residency with games
        #expect(call.environment["STEAM_CEF_COMMAND_LINE"]?.contains("--use-gl=swiftshader") == true)
        #expect(call.environment["STEAM_DISABLE_GPU_PROCESS"] == "1")
        // No WINEDLLOVERRIDES on the Steam launch: the winebus/SDL crash is fixed by removing libSDL2
        // (--without-sdl / stripBundledSDL), not a DLL override (which can't disable a PnP .sys driver).
        #expect(call.environment["WINEDLLOVERRIDES"] == nil)
    }


    // MARK: - Install error branches

    @Test("provision throws winebootFailed when wineboot --init returns non-zero")
    func winebootFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, _) = make(tmp)
        fake.queueResult(ProcessResult(exitCode: 5))   // the single wineboot --init call
        await #expect(throws: SteamBottle.BottleError.winebootFailed(5)) {
            try await bottle.provision(wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }

    @Test("installSteam throws installerDownloadFailed on a non-2xx installer download")
    func installerDownloadFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, _, _, _) = make(tmp, session: session)
        // wineboot uses the fake's default exit 0 (success); the download then 404s. The 404 is scoped
        // to THIS session — `Silo.steamInstallerURL` is fixed and other tests stub it with a 200.
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, statusCode: 404, data: Data(), session: session)
        await #expect(throws: SteamBottle.BottleError.installerDownloadFailed(404)) {
            try await bottle.installSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }

    @Test("installSteam throws steamInstallFailed when the silent SteamSetup run returns non-zero")
    func steamInstallFails() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, _) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        fake.queueResult(ProcessResult(exitCode: 0))   // wineboot --init succeeds
        fake.queueResult(ProcessResult(exitCode: 0))   // wineserver -k (settle the boot server)
        fake.queueResult(ProcessResult(exitCode: 1))   // SteamSetup.exe /S fails
        await #expect(throws: SteamBottle.BottleError.steamInstallFailed(1)) {
            try await bottle.installSteam(wine: URL(fileURLWithPath: "/w/wine64"))
        }
    }

    @Test("provision/installSteam/launchSteam throw wineNotConfigured when no wine is set")
    func wineNotConfigured() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, _) = make(tmp)
        await #expect(throws: SteamBottle.BottleError.wineNotConfigured) {
            try await bottle.provision(wine: nil)
        }
        await #expect(throws: SteamBottle.BottleError.wineNotConfigured) {
            try await bottle.installSteam(wine: nil)
        }
        await #expect(throws: SteamBottle.BottleError.wineNotConfigured) {
            _ = try await bottle.launchSteam(wine: nil)
        }
    }

    // MARK: - resetLogin

    @Test("resetLogin removes loginusers.vdf and ssfn tokens but spares everything else")
    func resetLoginScoped() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        let client = paths.steamBottleClientDir
        let fm = FileManager.default
        try fm.createDirectory(at: client.appendingPathComponent("config"), withIntermediateDirectories: true)
        // Files that MUST be removed:
        let loginUsers = client.appendingPathComponent("config/loginusers.vdf")
        try "users".write(to: loginUsers, atomically: true, encoding: .utf8)
        let ssfn1 = client.appendingPathComponent("ssfn123")
        let ssfn2 = client.appendingPathComponent("ssfn456789")
        try "tok1".write(to: ssfn1, atomically: true, encoding: .utf8)
        try "tok2".write(to: ssfn2, atomically: true, encoding: .utf8)
        // Files that MUST survive (guards against an over-broad match):
        let configVdf = client.appendingPathComponent("config/config.vdf")
        try "cfg".write(to: configVdf, atomically: true, encoding: .utf8)
        let libFolders = client.appendingPathComponent("libraryfolders.vdf")
        try "libs".write(to: libFolders, atomically: true, encoding: .utf8)
        let notSsfn = client.appendingPathComponent("not_ssfn.txt")   // contains but doesn't START with ssfn
        try "x".write(to: notSsfn, atomically: true, encoding: .utf8)

        try bottle.resetLogin()

        #expect(!fm.fileExists(atPath: loginUsers.path))
        #expect(!fm.fileExists(atPath: ssfn1.path))
        #expect(!fm.fileExists(atPath: ssfn2.path))
        #expect(fm.fileExists(atPath: configVdf.path))          // config dir + config.vdf untouched
        #expect(fm.fileExists(atPath: libFolders.path))
        #expect(fm.fileExists(atPath: notSsfn.path))            // prefix match, not substring

        // Idempotent: a second call on the now-cleaned dir doesn't throw.
        #expect(throws: Never.self) { try bottle.resetLogin() }
    }

    @Test("resetLogin is safe when Steam isn't installed (no client dir)")
    func resetLoginSafeWhenAbsent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, _) = make(tmp)   // nothing created under steamBottleClientDir
        #expect(throws: Never.self) { try bottle.resetLogin() }
    }

    // MARK: - installWebHelperWrapper no-op guards

    @Test("installWebHelperWrapper is a no-op on a runtime that predates the wrapper")
    func webHelperWrapperMissingRuntime() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        // Older runtime: wine binary exists but NO share/silo/steamwebhelper-wrapper.exe.
        let wine = tmp.url.appendingPathComponent("wine/bin/wine64")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A real Steam webhelper is present in the bottle.
        let helper = paths.steamBottleCEFDir.appendingPathComponent("cef.win7x64/steamwebhelper.exe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "REAL".write(to: helper, atomically: true, encoding: .utf8)

        try bottle.installWebHelperWrapper(wine: wine)   // must not throw

        let orig = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
        #expect(try String(contentsOf: helper, encoding: .utf8) == "REAL")          // untouched
        #expect(FileManager.default.fileExists(atPath: orig.path) == false)         // no _orig created
    }

    @Test("installWebHelperWrapper is a no-op before Steam is installed (no CEF dir)")
    func webHelperWrapperSteamNotInstalled() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        // Runtime DOES ship the wrapper, but Steam isn't installed → no steamBottleCEFDir.
        let wine = tmp.url.appendingPathComponent("wine/bin/wine64")
        _ = try tmp.write("wine/share/silo/steamwebhelper-wrapper.exe", "WRAPPER")

        #expect(bottle.webHelpers().isEmpty)             // internal, via @testable import
        try bottle.installWebHelperWrapper(wine: wine)   // must not throw
        #expect(FileManager.default.fileExists(atPath: paths.steamBottleCEFDir.path) == false)
    }

    @Test("installWebHelperWrapper preserves the real webhelper and drops the wrapper in its place")
    func webHelperWrapper() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        // The wine runtime ships the wrapper at <wineRoot>/share/silo/.
        let wine = tmp.url.appendingPathComponent("wine/bin/wine64")
        _ = try tmp.write("wine/share/silo/steamwebhelper-wrapper.exe", "WRAPPER")
        // Steam installed its real webhelper in the bottle.
        let helper = paths.steamBottleCEFDir.appendingPathComponent("cef.win7x64/steamwebhelper.exe")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "REAL".write(to: helper, atomically: true, encoding: .utf8)

        try bottle.installWebHelperWrapper(wine: wine)
        let orig = helper.deletingLastPathComponent().appendingPathComponent("steamwebhelper_orig.exe")
        #expect(try String(contentsOf: helper, encoding: .utf8) == "WRAPPER")   // wrapper in place
        #expect(try String(contentsOf: orig, encoding: .utf8) == "REAL")        // real one preserved

        // Idempotent: a second call doesn't clobber the preserved real binary.
        try bottle.installWebHelperWrapper(wine: wine)
        #expect(try String(contentsOf: orig, encoding: .utf8) == "REAL")

        // A NEW wrapper version (changed CEF flags) replaces the stale wrapper but keeps the real `_orig`
        // — must NOT move the stale wrapper over the genuine preserved binary.
        try "WRAPPER_V2".write(to: wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/silo/steamwebhelper-wrapper.exe"), atomically: true, encoding: .utf8)
        try bottle.installWebHelperWrapper(wine: wine)
        #expect(try String(contentsOf: helper, encoding: .utf8) == "WRAPPER_V2")   // new wrapper in place
        #expect(try String(contentsOf: orig, encoding: .utf8) == "REAL")           // real one still intact

        // A Steam update adds a SECOND cef dir (cef.win64) with a fresh real webhelper — it must ALSO get
        // wrapped, else Steam runs the unwrapped one and the window is black.
        let cef2 = paths.steamBottleCEFDir.appendingPathComponent("cef.win64")
        try FileManager.default.createDirectory(at: cef2, withIntermediateDirectories: true)
        try "REAL2".write(to: cef2.appendingPathComponent("steamwebhelper.exe"), atomically: true, encoding: .utf8)
        try bottle.installWebHelperWrapper(wine: wine)
        #expect(try String(contentsOf: cef2.appendingPathComponent("steamwebhelper.exe"), encoding: .utf8) == "WRAPPER_V2")
        #expect(try String(contentsOf: cef2.appendingPathComponent("steamwebhelper_orig.exe"), encoding: .utf8) == "REAL2")
    }

    @Test("installCoreFonts runs the FIRST font user-guided (no /Q) and the rest silently, into Fonts")
    func installCoreFonts() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        for font in Silo.coreFonts {
            FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe").absoluteString,
                                 data: Data("EXE".utf8), session: session)
        }
        let fontsDir = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        let extractDir = paths.steamBottle.appendingPathComponent("drive_c/silo-fonts")
        let firstFont = Silo.coreFonts[0]   // andale32 — user-guided (EULA), installs itself into Fonts
        // Simulate the installers: the FIRST font runs BARE (no /C) → installs its .ttf straight into Fonts;
        // the rest run `/C` extract-only → drop the .ttf into the extract dir for Silo to copy.
        fake.onRun = { inv in
            guard let exeArg = inv.arguments.first(where: { $0.hasSuffix(".exe") }) else { return }
            let font = (exeArg.split(separator: "\\").last.map(String.init) ?? exeArg)
                .replacingOccurrences(of: ".exe", with: "")
            if inv.arguments.contains("/C") {
                try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                let ttf = font == "arial32" ? "Arial.TTF" : "\(font).TTF"
                FileManager.default.createFile(atPath: extractDir.appendingPathComponent(ttf).path, contents: Data("TTF".utf8))
            } else if font == firstFont {
                try? FileManager.default.createDirectory(at: fontsDir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: fontsDir.appendingPathComponent("\(font).TTF").path, contents: Data("TTF".utf8))
            }
        }

        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))

        // First font ran USER-GUIDED (bare — no /Q); every subsequent font ran silent (/Q).
        let fontRuns = fake.invocations.filter { $0.arguments.first?.hasSuffix(".exe") == true }
        #expect(fontRuns.count == Silo.coreFonts.count)
        #expect(fontRuns.first?.arguments.contains("/Q") == false)                  // first: EULA shown
        #expect(fontRuns.dropFirst().allSatisfy { $0.arguments.contains("/Q") })    // rest: silent
        let installed = Set((try? FileManager.default.contentsOfDirectory(atPath: fontsDir.path)) ?? [])
        #expect(installed.contains("Arial.TTF"))                 // marker font landed in Fonts
        #expect(installed.count == Silo.coreFonts.count)         // one .ttf per installer
        #expect(bottle.hasCoreFonts)
        // Idempotent: a second run does no downloads/runs (the marker short-circuits it).
        let runsBefore = fake.invocations.count
        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.count == runsBefore)
    }

    @Test("a resumed core-fonts install with the EULA already accepted does NOT re-prompt (first font runs silent)")
    func coreFontsResumeSkipsEULA() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        for font in Silo.coreFonts {
            FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe").absoluteString,
                                 data: Data("EXE".utf8), session: session)
        }
        // Record the EULA as accepted on a prior run, but leave Arial absent so `hasCoreFonts` is false and
        // the loop actually re-enters from index 0 (the partial-failure resume the marker exists to handle).
        let markerDir = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: markerDir.appendingPathComponent("corefonts-eula").path, contents: Data())

        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))

        // EVERY font — including the first (Andale) — ran SILENT (/Q): no license re-prompt on resume.
        let fontRuns = fake.invocations.filter { $0.arguments.first?.hasSuffix(".exe") == true }
        #expect(fontRuns.count == Silo.coreFonts.count)
        #expect(fontRuns.allSatisfy { $0.arguments.contains("/Q") })
    }

    @Test("installCoreFonts verifies each font's pinned SHA-256 and drops a mismatch (never executes it)")
    func coreFontsVerifyDigest() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let stub = Data("FONT-INSTALLER-BYTES".utf8)
        // andale32 (the user-guided first font) is pinned to the stub's REAL digest → accepted + executed;
        // arial32 is pinned to a WRONG digest → the downloaded .exe is rejected + never executed.
        let (bottle, fake, _, _) = make(
            tmp, session: session,
            coreFontDigests: ["andale32": sha256Hex(stub), "arial32": String(repeating: "0", count: 64)])
        FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("andale32.exe").absoluteString,
                             data: stub, session: session)
        FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("arial32.exe").absoluteString,
                             data: stub, session: session)

        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))

        let ranExes = Set(fake.invocations.compactMap { $0.arguments.first(where: { $0.hasSuffix(".exe") }) })
        #expect(ranExes.contains("C:\\andale32.exe"))    // matching digest → executed
        #expect(!ranExes.contains("C:\\arial32.exe"))     // wrong digest → dropped, never executed
    }

    @Test("every core font + both d3dcompiler cabs have a 64-hex pinned SHA-256 (fail-open-on-missing is safe)")
    func pinnedDigestsAreComplete() {
        for font in Silo.coreFonts {
            #expect(Silo.coreFontSHA256[font]?.count == 64, "missing/short pin for \(font)")
        }
        #expect(Silo.d3dCompiler47X64CabSHA256.count == 64)
        #expect(Silo.d3dCompiler47X86CabSHA256.count == 64)
    }

    // MARK: - Game-dependency components

    @Test("installSourceHanSans downloads the 4 packs, extracts each, copies .otf into Fonts, per-pack markers")
    func installSourceHanSans() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        for pack in Silo.sourceHanSansPacks {
            FakeURLProtocol.stub(Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip").absoluteString,
                                 data: Data("ZIP".utf8), session: session)
        }
        let fontsDir = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        let extractDir = paths.steamBottle.appendingPathComponent("drive_c/silo-shs")
        // Simulate bsdtar: each `tar -xf <pack>.zip` drops a Regular .otf into the extract dir.
        fake.onRun = { inv in
            guard inv.executable.path == "/usr/bin/tar",
                  let zipArg = inv.arguments.first(where: { $0.hasSuffix(".zip") }) else { return }
            let pack = (zipArg as NSString).lastPathComponent.replacingOccurrences(of: ".zip", with: "")
            try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: extractDir.appendingPathComponent("\(pack)-Regular.otf").path, contents: Data("OTF".utf8))
        }

        try await bottle.installSourceHanSans()

        let tarRuns = fake.invocations.filter { $0.executable.path == "/usr/bin/tar" && $0.arguments.first == "-xf" }
        #expect(tarRuns.count == Silo.sourceHanSansPacks.count)   // one extract per pack
        let installed = Set((try? FileManager.default.contentsOfDirectory(atPath: fontsDir.path)) ?? [])
        for pack in Silo.sourceHanSansPacks { #expect(installed.contains("\(pack)-Regular.otf")) }
        #expect(bottle.hasSourceHanSans)
        // Idempotent: second run does nothing.
        let runsBefore = fake.invocations.count
        try await bottle.installSourceHanSans()
        #expect(fake.invocations.count == runsBefore)
    }

    @Test("installSourceHanSans resumes — a pack with an existing marker is skipped (no re-download)")
    func sourceHanSansResumes() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        // Pre-mark the first pack as already installed.
        let markers = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: markers.appendingPathComponent(Silo.sourceHanSansPacks[0]).path, contents: Data())
        for pack in Silo.sourceHanSansPacks.dropFirst() {
            FakeURLProtocol.stub(Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip").absoluteString,
                                 data: Data("ZIP".utf8), session: session)
        }
        fake.onRun = { _ in }

        try await bottle.installSourceHanSans()

        // Only the 3 remaining packs were extracted (the marked one was skipped).
        let tarRuns = fake.invocations.filter { $0.executable.path == "/usr/bin/tar" }
        #expect(tarRuns.count == Silo.sourceHanSansPacks.count - 1)
    }

    @Test("installSourceHanSans does NOT mark a pack whose extract yielded no .otf (retried next run)")
    func sourceHanSansEmptyExtractNotMarked() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        for pack in Silo.sourceHanSansPacks {
            FakeURLProtocol.stub(Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip").absoluteString,
                                 data: Data("ZIP".utf8), session: session)
        }
        fake.onRun = { _ in }   // tar exits 0 but extracts NOTHING (truncated/misformatted archive)

        try await bottle.installSourceHanSans()

        // No .otf copied ⇒ no per-pack marker ⇒ not "installed", so a later Set up retries it.
        #expect(!bottle.hasSourceHanSans)
        let markerDir = paths.steamBottle.appendingPathComponent(".silo-installed")
        for pack in Silo.sourceHanSansPacks {
            #expect(!FileManager.default.fileExists(atPath: markerDir.appendingPathComponent(pack).path))
        }
    }

    @Test("installD3DCompiler47 extracts both ABIs via `wine expand` and sets a native override")
    func installD3DCompiler47() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        FakeURLProtocol.stub(Silo.d3dCompiler47X64CabURL.absoluteString, data: Data("CAB64".utf8), session: session)
        FakeURLProtocol.stub(Silo.d3dCompiler47X86CabURL.absoluteString, data: Data("CAB32".utf8), session: session)
        let sys32 = paths.steamBottle.appendingPathComponent("drive_c/windows/system32")
        let syswow = paths.steamBottle.appendingPathComponent("drive_c/windows/syswow64")
        // Simulate `wine expand <cab> -F:<member> C:\windows\<dir>`: drop the member-named file into the dir.
        fake.onRun = { inv in
            guard inv.arguments.first == "expand",
                  let memberArg = inv.arguments.first(where: { $0.hasPrefix("-F:") }) else { return }
            let member = String(memberArg.dropFirst(3))
            let dir = inv.arguments.contains("C:\\windows\\system32") ? sys32 : syswow
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The REAL d3dcompiler_47.dll is multi-MB; write a large-enough dummy to pass the size gate.
            FileManager.default.createFile(atPath: dir.appendingPathComponent(member).path, contents: Data(count: 600_000))
        }

        try await bottle.installD3DCompiler47(wine: URL(fileURLWithPath: "/w/wine64"))

        // Both DLLs landed (renamed from the member id → canonical name).
        #expect(FileManager.default.fileExists(atPath: sys32.appendingPathComponent("d3dcompiler_47.dll").path))
        #expect(FileManager.default.fileExists(atPath: syswow.appendingPathComponent("d3dcompiler_47.dll").path))
        #expect(bottle.hasD3DCompiler47)
        // The expand runs carried the correct member ids + windows dest dirs.
        let expands = fake.invocations.filter { $0.arguments.first == "expand" }
        #expect(expands.contains { $0.arguments.contains("-F:\(Silo.d3dCompiler47X64Member)") && $0.arguments.contains("C:\\windows\\system32") })
        #expect(expands.contains { $0.arguments.contains("-F:\(Silo.d3dCompiler47X86Member)") && $0.arguments.contains("C:\\windows\\syswow64") })
        // NO DLL override is written — the native file is present, so Wine's load order picks it up.
        #expect(!fake.invocations.contains {
            ($0.arguments.first == "reg" || $0.arguments.first == "regedit") && $0.arguments.contains("d3dcompiler_47")
        })
        // Idempotent.
        let runsBefore = fake.invocations.count
        try await bottle.installD3DCompiler47(wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.count == runsBefore)
    }

    @Test("installVCRedist runs the redist USER-GUIDED (no /quiet) and marks it done on success")
    func installVCRedist() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, _, _) = make(tmp, session: session)
        FakeURLProtocol.stub(Silo.vcRedistX64URL.absoluteString, data: Data("EXE".utf8), session: session)
        // The installer run returns the fake's default exit 0 → a success → the Silo marker is written.

        try await bottle.installVCRedist(x86: false, wine: URL(fileURLWithPath: "/w/wine64"))

        let run = try #require(fake.invocations.last { $0.arguments.first?.hasSuffix("vc_redist.x64.exe") == true })
        #expect(run.arguments.count == 1)                    // just the installer path — no /install /quiet
        #expect(!run.arguments.contains("/quiet"))           // user-guided (license shown)
        #expect(bottle.isVCRedistInstalled(x86: false))      // marked done (exit 0), NOT via msvcp140.dll
        // Idempotent.
        let runsBefore = fake.invocations.count
        try await bottle.installVCRedist(x86: false, wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.count == runsBefore)
    }

    @Test("a user cancel (exit 1602) FAILS setup (componentCancelled) and leaves MSVC UNMARKED to re-prompt")
    func vcRedistCancelFailsSetup() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, _, _) = make(tmp, session: session)
        FakeURLProtocol.stub(Silo.vcRedistX86URL.absoluteString, data: Data("EXE".utf8), session: session)
        fake.queueResult(ProcessResult(exitCode: 1602))   // user cancelled the bootstrapper

        await #expect(throws: SteamBottle.BottleError.componentCancelled(.vcRedistX86)) {
            try await bottle.installVCRedist(x86: true, wine: URL(fileURLWithPath: "/w/wine64"))
        }
        #expect(!bottle.isVCRedistInstalled(x86: true))   // NOT marked → the next setup runs it again
    }

    @Test("declining the core-fonts license installs nothing but does NOT fail setup (best-effort; re-prompts)")
    func coreFontsDeclineIsBestEffort() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        for font in Silo.coreFonts {
            FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe").absoluteString,
                                 data: Data("EXE".utf8), session: session)
        }
        fake.onRun = { _ in }   // nothing extracts to silo-fonts → simulates the user DECLINING the license

        // Best-effort: the (unreliable-under-Wine) installer exit code is no longer treated as a cancel, so
        // this must NOT throw — a declined font is simply skipped, it doesn't halt the whole setup.
        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))

        #expect(!bottle.hasCoreFonts)                                    // nothing extracted ⇒ nothing installed
        // Acceptance is NOT recorded, so a resumed Set up re-shows the license.
        let eulaMarker = paths.steamBottle.appendingPathComponent(".silo-installed/corefonts-eula")
        #expect(!FileManager.default.fileExists(atPath: eulaMarker.path))
        // The first font still ran WITHOUT /Q (the license prompt); the decline just didn't install anything.
        let fontRuns = fake.invocations.filter { $0.arguments.first?.hasSuffix(".exe") == true }
        #expect(fontRuns.first?.arguments.contains("/Q") == false)
    }

    @Test("provisionComponents rethrows a user cancel — setup STOPS before Steam (not best-effort)")
    func provisionComponentsCancelIsFatal() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        // Satisfy every component BEFORE vcRedistX86 so it's the first to actually run, then cancel it.
        let driveC = paths.steamBottle.appendingPathComponent("drive_c")
        let fonts = driveC.appendingPathComponent("windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())
        let markers = paths.steamBottle.appendingPathComponent(".silo-installed")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        for pack in Silo.sourceHanSansPacks {
            FileManager.default.createFile(atPath: markers.appendingPathComponent(pack).path, contents: Data())
        }
        for dir in ["windows/system32", "windows/syswow64"] {
            let d = driveC.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: d.appendingPathComponent("d3dcompiler_47.dll").path, contents: Data(count: 600_000))
        }
        FakeURLProtocol.stub(Silo.vcRedistX86URL.absoluteString, data: Data("EXE".utf8), session: session)
        fake.queueResult(ProcessResult(exitCode: 1602))   // user cancels the x86 redist

        await #expect(throws: SteamBottle.BottleError.componentCancelled(.vcRedistX86)) {
            try await bottle.provisionComponents(wine: URL(fileURLWithPath: "/w/wine64")) { _ in }
        }
        // The terminal Steam component never installed — provisioning stopped at the cancel.
        #expect(!fake.invocations.contains { $0.arguments.first?.hasSuffix("SteamSetup.exe") == true })
    }

    @Test("a Wine fakedll stub does NOT mark d3dcompiler_47 / MSVC installed (they still run)")
    func fakeDllStubsDoNotSatisfyComponents() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, _, paths) = make(tmp)
        // Wine's wineboot drops tiny placeholder ("fake") DLLs for its builtins into system32/syswow64.
        for dir in ["windows/system32", "windows/syswow64"] {
            let d = paths.steamBottle.appendingPathComponent("drive_c/\(dir)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: d.appendingPathComponent("d3dcompiler_47.dll").path, contents: Data(count: 8_000))
            FileManager.default.createFile(atPath: d.appendingPathComponent("msvcp140.dll").path, contents: Data(count: 120_000))
        }
        #expect(!bottle.hasD3DCompiler47)                  // tiny stub ≠ the real multi-MB DLL
        #expect(!bottle.isVCRedistInstalled(x86: true))    // no Silo marker → not installed
        #expect(!bottle.isVCRedistInstalled(x86: false))
    }

    @Test("runSteamInstaller user-guided omits /S (the interactive GUI installer)")
    func runSteamInstallerUserGuided() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, _, _) = make(tmp, session: session)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8), session: session)

        try await bottle.runSteamInstaller(wine: URL(fileURLWithPath: "/w/wine64"), userGuided: true)

        let run = try #require(fake.invocations.last { $0.arguments.first?.hasSuffix("SteamSetup.exe") == true })
        #expect(!run.arguments.contains("/S"))               // user-guided — no silent flag
    }

    // MARK: - Ordered provisioning

    @Test("provisionComponents installs the component set in the fixed order (msync skipped — a no-op)")
    func provisionComponentsOrder() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, _, _, _) = make(tmp, session: session)
        // Stub every component's download so each install can proceed (success is irrelevant to ordering —
        // the phase fires BEFORE each install).
        for font in Silo.coreFonts {
            FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe").absoluteString, data: Data("X".utf8), session: session)
        }
        for pack in Silo.sourceHanSansPacks {
            FakeURLProtocol.stub(Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip").absoluteString, data: Data("X".utf8), session: session)
        }
        FakeURLProtocol.stub(Silo.d3dCompiler47X64CabURL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.d3dCompiler47X86CabURL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.vcRedistX86URL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.vcRedistX64URL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("X".utf8), session: session)

        let phases = LockedBox<[BottleComponent]>([])
        try await bottle.provisionComponents(wine: URL(fileURLWithPath: "/w/wine64")) { component in
            phases.set(phases.value + [component])
        }

        // msync is always satisfied (launch-time env var) → skipped, never a phase, zero process work.
        #expect(phases.value == [.coreFonts, .sourceHanSans, .d3dcompiler47, .vcRedistX86, .vcRedistX64, .steamClient])
    }

    @Test("provisionComponents skips already-satisfied components")
    func provisionComponentsSkipsSatisfied() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, _, paths, _) = make(tmp, session: session)
        // Pre-satisfy coreFonts (Arial.TTF) + steamClient (steam.exe); leave the rest unsatisfied.
        let fonts = paths.steamBottle.appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fonts.appendingPathComponent("Arial.TTF").path, contents: Data())
        try FileManager.default.createDirectory(at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        // Stub the remaining components so they can proceed.
        for pack in Silo.sourceHanSansPacks {
            FakeURLProtocol.stub(Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip").absoluteString, data: Data("X".utf8), session: session)
        }
        FakeURLProtocol.stub(Silo.d3dCompiler47X64CabURL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.d3dCompiler47X86CabURL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.vcRedistX86URL.absoluteString, data: Data("X".utf8), session: session)
        FakeURLProtocol.stub(Silo.vcRedistX64URL.absoluteString, data: Data("X".utf8), session: session)

        let phases = LockedBox<[BottleComponent]>([])
        try await bottle.provisionComponents(wine: URL(fileURLWithPath: "/w/wine64")) { component in
            phases.set(phases.value + [component])
        }

        #expect(!phases.value.contains(.coreFonts))    // Arial.TTF present → skipped
        #expect(!phases.value.contains(.steamClient))  // steam.exe present → skipped
        #expect(phases.value.contains(.sourceHanSans)) // not installed → fired
        #expect(phases.value.contains(.vcRedistX86))
    }

    // MARK: - Default Wine DLL overrides

    @Test("defaultDllOverrides is the complete Windows-compatibility override set (pin)")
    func defaultDllOverridesAreComplete() {
        let overrides = Silo.defaultDllOverrides
        let byName = Dictionary(uniqueKeysWithValues: overrides.map { ($0.name, $0.mode) })
        // The exact size of the standard override set.
        #expect(overrides.count == 58)
        // The runtime DLLs Silo installs natively are deliberately NOT overridden — Wine's load order
        // picks up the real files once they're present.
        for absent in ["msvcp140", "vcruntime140", "d3dcompiler_47", "concrt140"] {
            #expect(byName[absent] == nil, "\(absent) must NOT be overridden")
        }
        // Representative entries incl. the edge cases (disabled / native-only / builtin-only / app wildcard).
        #expect(byName["*docbox.api"] == "")                 // disabled
        #expect(byName["dciman32"] == "native")              // native-only
        #expect(byName["ole32"] == "builtin")                // builtin-only
        #expect(byName["*ctfmon.exe"] == "builtin")          // app wildcard, builtin
        #expect(byName["mshtml"] == "native,builtin")
        #expect(byName["*user.exe"] == "native,builtin")
        #expect(byName["wscript.exe"] == "native,builtin")
        // No stray whitespace in any mode (Wine trims, but keep the constant clean).
        #expect(overrides.allSatisfy { !$0.mode.contains(" ") })
    }

    @Test("applyWineDefaults imports the default DllOverrides via one regedit /S and marks the bottle")
    func applyWineDefaults() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, paths) = make(tmp)
        let regFile = paths.steamBottle.appendingPathComponent("drive_c/silo-overrides.reg")
        // Capture the .reg content during the run (it's deleted afterward).
        let captured = LockedBox<String?>(nil)
        fake.onRun = { inv in
            if inv.arguments.first == "regedit" { captured.set(try? String(contentsOf: regFile, encoding: .utf8)) }
        }

        await bottle.applyWineDefaults(wine: URL(fileURLWithPath: "/w/wine64"))

        // ONE silent regedit import.
        let reg = try #require(fake.invocations.last { $0.arguments.first == "regedit" })
        #expect(reg.arguments.contains("/S"))
        #expect(fake.invocations.filter { $0.arguments.first == "regedit" }.count == 1)
        // The emitted .reg carried the DllOverrides block + representative overrides.
        let content = try #require(captured.value)
        #expect(content.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]"))
        #expect(content.contains("\"mshtml\"=\"native,builtin\""))
        #expect(content.contains("\"ole32\"=\"builtin\""))
        #expect(content.contains("\"dciman32\"=\"native\""))
        #expect(content.contains("\"*docbox.api\"=\"\""))
        #expect(!content.contains("d3dcompiler_47"))         // not overridden
        #expect(bottle.hasWineDefaults)
        // Idempotent: a second call does nothing.
        let runsBefore = fake.invocations.count
        await bottle.applyWineDefaults(wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.count == runsBefore)
    }

}
