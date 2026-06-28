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

    @Test("launchSteam(hardwareAccelerated:) uses the GPU CEF path + overlaid-D3DMetal DYLD, no SwiftShader")
    func launchSteamHardware() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (bottle, fake, _) = make(tmp)
        _ = try await bottle.launchSteam(wine: URL(fileURLWithPath: "/rt/bin/wine64"), hardwareAccelerated: true)
        let call = try #require(fake.lastInvocation)
        #expect(call.arguments.contains("-cef-in-process-gpu"))
        #expect(!call.arguments.contains("-cef-disable-gpu"))                    // GPU is NOT disabled
        let cef = call.environment["STEAM_CEF_COMMAND_LINE"] ?? ""
        #expect(!cef.contains("swiftshader"))                                    // not software GL
        #expect(!cef.contains("--disable-gpu"))
        #expect(call.environment["STEAM_DISABLE_GPU_PROCESS"] == nil)            // GPU process kept
        // DYLD points at the wine runtime's overlaid D3DMetal so CEF's ANGLE D3D11 can reach Metal.
        #expect(call.environment["DYLD_FALLBACK_FRAMEWORK_PATH"] == "/rt/lib/external")
        #expect(call.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix("/rt/lib/external:") == true)
        #expect(call.environment["WINEDLLOVERRIDES"]?.contains("d3d11") == true)
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

}
