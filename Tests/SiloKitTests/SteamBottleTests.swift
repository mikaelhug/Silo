import Foundation
import Testing
@testable import SiloKit

@Suite("SteamBottle")
struct SteamBottleTests {

    private func make(_ tmp: TempDir) -> (SteamBottle, FakeProcessRunner, AppPaths) {
        let (bottle, fake, paths, _) = make(tmp, session: FakeURLProtocol.makeSession())
        return (bottle, fake, paths)
    }

    /// Variant that exposes the session, so a test can register a session-scoped stub for the fixed
    /// `Silo.steamInstallerURL` without colliding with other tests stubbing the same URL.
    private func make(_ tmp: TempDir, session: URLSession)
        -> (SteamBottle, FakeProcessRunner, AppPaths, URLSession) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: session, paths: paths)
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

    @Test("installCoreFonts downloads each font, extracts its .ttf via IExpress, and copies it into Fonts")
    func installCoreFonts() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let session = FakeURLProtocol.makeSession()
        let (bottle, fake, paths, _) = make(tmp, session: session)
        // Stub every corefont installer download.
        for font in Silo.coreFonts {
            FakeURLProtocol.stub(Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe").absoluteString,
                                 data: Data("EXE".utf8), session: session)
        }
        let fontsDir = paths.steamBottle(.gptk).appendingPathComponent("drive_c/windows/Fonts")
        let extractDir = paths.steamBottle(.gptk).appendingPathComponent("drive_c/silo-fonts")
        // Simulate the IExpress extract: drop a .ttf named after the font (Arial.TTF for arial32, the marker).
        fake.onRun = { inv in
            guard inv.arguments.contains("/C"), let exeArg = inv.arguments.first(where: { $0.hasSuffix(".exe") })
            else { return }
            // The exe arg is a Windows path (C:\arial32.exe) — split on backslash, not `/`.
            let font = (exeArg.split(separator: "\\").last.map(String.init) ?? exeArg)
                .replacingOccurrences(of: ".exe", with: "")
            try? FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let ttf = font == "arial32" ? "Arial.TTF" : "\(font).TTF"
            FileManager.default.createFile(atPath: extractDir.appendingPathComponent(ttf).path, contents: Data("TTF".utf8))
        }

        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))

        let installed = Set((try? FileManager.default.contentsOfDirectory(atPath: fontsDir.path)) ?? [])
        #expect(installed.contains("Arial.TTF"))                 // marker font landed in Fonts
        #expect(installed.count == Silo.coreFonts.count)         // one .ttf per installer
        #expect(bottle.hasCoreFonts)                             // idempotency marker now true
        // Idempotent: a second run does no downloads (the marker short-circuits it).
        let extractRunsBefore = fake.invocations.count
        try await bottle.installCoreFonts(wine: URL(fileURLWithPath: "/w/wine64"))
        #expect(fake.invocations.count == extractRunsBefore)
    }

    @Test("seedFromCompleteBottle clones a sibling's CLIENT (not its games/login) + fonts, no download")
    func seedFromSibling() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        // GPTK bottle: a complete client (steamui.dll + a CEF webhelper) + a core font.
        let gptkSteam = paths.steamBottleClientDir(.gptk)
        let gptkCef = gptkSteam.appendingPathComponent("bin/cef/cef.win7x64")
        try FileManager.default.createDirectory(at: gptkCef, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gptkSteam.appendingPathComponent("steamui.dll").path, contents: Data("UI".utf8))
        FileManager.default.createFile(atPath: gptkCef.appendingPathComponent("steamwebhelper.exe").path, contents: Data("WH".utf8))
        let gptkFonts = paths.steamBottle(.gptk).appendingPathComponent("drive_c/windows/Fonts")
        try FileManager.default.createDirectory(at: gptkFonts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gptkFonts.appendingPathComponent("Arial.TTF").path, contents: Data("F".utf8))
        // …plus per-instance state that must NOT be seeded: installed games + a saved login.
        let gptkApps = gptkSteam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: gptkApps, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gptkApps.appendingPathComponent("appmanifest_220.acf").path, contents: Data("acf".utf8))
        let gptkConfig = gptkSteam.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: gptkConfig, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: gptkConfig.appendingPathComponent("loginusers.vdf").path, contents: Data("login".utf8))
        FileManager.default.createFile(atPath: gptkSteam.appendingPathComponent("ssfn12345").path, contents: Data("tok".utf8))

        // DXMT bottle: fresh — seeds from the GPTK sibling.
        let dxmt = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths, backend: .dxmt)
        #expect(!dxmt.isClientFullyDownloaded)
        let seeded = await dxmt.seedFromCompleteBottle(wine: URL(fileURLWithPath: "/w/wine64"))

        #expect(seeded)
        #expect(dxmt.isClientFullyDownloaded)          // client cloned (steamui + webhelper)
        #expect(dxmt.hasCoreFonts)                      // fonts cloned too
        // No SteamSetup download-install ran — provisioned + cloned only.
        #expect(!fake.invocations.contains { $0.arguments.contains { $0.hasSuffix("SteamSetup.exe") } })
        // The game library + login are NOT seeded (the fix): the new bottle is fresh, so discovery can't
        // list the sibling's games under this backend too, and there's no inherited sign-in.
        let dxmtSteam = paths.steamBottleClientDir(.dxmt)
        #expect(FileManager.default.fileExists(atPath: dxmtSteam.appendingPathComponent("steamui.dll").path))   // client IS seeded
        #expect(!FileManager.default.fileExists(atPath: dxmtSteam.appendingPathComponent("steamapps").path))    // games are NOT
        #expect(!FileManager.default.fileExists(atPath: dxmtSteam.appendingPathComponent("config").path))       // login is NOT
        #expect(!FileManager.default.fileExists(atPath: dxmtSteam.appendingPathComponent("ssfn12345").path))    // machine token NOT

        // Returns false when no sibling has a complete client (nothing to clone → normal install path).
        let tmp2 = try TempDir(); defer { tmp2.cleanup() }
        let solo = SteamBottle(runner: FakeProcessRunner(), session: FakeURLProtocol.makeSession(),
                               paths: AppPaths(supportDir: tmp2.url.appendingPathComponent("Silo")), backend: .dxmt)
        #expect(await solo.seedFromCompleteBottle(wine: URL(fileURLWithPath: "/w/wine64")) == false)
    }

}
