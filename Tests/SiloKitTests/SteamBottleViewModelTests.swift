import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("SteamBottleViewModel")
struct SteamBottleViewModelTests {

    private func make(_ tmp: TempDir, focuser: GuidedInstallFocusing? = nil)
        -> (SteamBottleViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let session = SteamClientSession(
            bottle: bottle, orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        session.readinessTimeout = 0
        // Collapse the setup warm-up so `setUp()` doesn't poll for real: the fake never "commits" Steam's
        // update, so warm-up runs to its failsafe — with these tuned to ~0 it returns near-instantly.
        session.warmUpPollInterval = 0.001
        session.warmUpTimeout = 0.005
        session.warmUpMaxRelaunches = 0
        session.warmUpBringUpTimeout = 0.005
        session.warmUpCefSettleSeconds = 0.002
        session.warmUpForceQuitSettle = 0
        let vm = SteamBottleViewModel(bottle: bottle, session: session, focuser: focuser)
        return (vm, fake, paths)
    }

    /// Records arm/disarm so a test can assert the setup flow focuses the user-guided installer windows.
    @MainActor
    final class SpyFocuser: GuidedInstallFocusing {
        private(set) var armedRoots: [URL] = []
        private(set) var disarmCount = 0
        func arm(wineRoot: URL) { armedRoots.append(wineRoot) }
        func disarm() { disarmCount += 1 }
    }

    @Test("steamInstalled is a cache: refreshInstalled() probes off-main; setUp sets it + fires the hook")
    func steamInstalledCache() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        #expect(!vm.steamInstalled)

        try FileManager.default.createDirectory(
            at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        // A bare bootstrapper is NOT "installed" anymore — the probe keys on the warmed client.
        await vm.refreshInstalled()
        #expect(!vm.steamInstalled)
        // Warm the client: steamui.dll + a CEF webhelper (what steamInstalled now keys on).
        FileManager.default.createFile(
            atPath: paths.steamBottleClientDir.appendingPathComponent("steamui.dll").path, contents: Data())
        let cef = paths.steamBottleCEFDir.appendingPathComponent("cef.win7x64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())
        #expect(!vm.steamInstalled)          // still the cache — no probe yet
        await vm.refreshInstalled()
        #expect(vm.steamInstalled)

        // setUp on an already-installed bottle: success path sets the flag + fires onSteamInstalled.
        let hooked = LockedBox(false)
        vm.onSteamInstalled = { hooked.set(true) }
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))
        await vm.setUp()
        #expect(vm.steamInstalled && hooked.value)
    }

    @Test("canSetUp is gated on a configured wine binary")
    func canSetUpGate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, _) = make(tmp)
        #expect(!vm.canSetUp)                                // wineBinary == nil
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))
        #expect(vm.canSetUp)
    }

    @Test("setUp provisions the bottle and reports success (Steam user-guided)")
    func setUpSuccess() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        // Pre-satisfy the non-Steam components so setUp only runs the Steam install (no ~360 MB font network).
        paths.createComponentMarkers()
        // Simulate the user-guided Steam install + warm-up producing a WARMED client (steamui.dll + webhelper).
        fake.onRun = { inv in
            if inv.arguments.first?.hasSuffix("SteamSetup.exe") == true { paths.createWarmedSteamClient() }
        }
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))

        await vm.setUp()

        #expect(fake.invocations.contains { $0.arguments == ["wineboot", "--init"] })
        // Steam was installed USER-GUIDED (no /S — the interactive GUI).
        let steamRun = try #require(fake.invocations.last { $0.arguments.first?.hasSuffix("SteamSetup.exe") == true })
        #expect(!steamRun.arguments.contains("/S"))
        // The black-window guard force-quit any Steam the installer auto-launched, before the warm-up.
        #expect(fake.invocations.contains { $0.arguments.first == "taskkill" })
        #expect(vm.status.contains("Steam is ready"))
        #expect(vm.steamInstalled)
        #expect(!vm.busy)
    }

    @Test("setUp focuses the user-guided installer window during that step, then disarms")
    func setUpFocusesGuidedInstaller() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let spy = SpyFocuser()
        let (vm, fake, paths) = make(tmp, focuser: spy)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        // Pre-satisfy the non-Steam components so only the user-guided Steam client step runs.
        paths.createComponentMarkers()
        fake.onRun = { inv in
            if inv.arguments.first?.hasSuffix("SteamSetup.exe") == true { paths.createWarmedSteamClient() }
        }
        vm.updateWine(URL(fileURLWithPath: "/runtimes/wine/bin/wine64"))

        await vm.setUp()

        // The Steam step (user-guided) armed the focuser with the Wine runtime ROOT (parent of bin/)…
        #expect(spy.armedRoots.map(\.path) == ["/runtimes/wine"])
        // …and the focuser was disarmed by the time setup finished (never left armed).
        #expect(spy.disarmCount >= 1)
    }

    @Test("setupFailureMessage reads a cancelled installer as a pause with a retry cue")
    func setupFailureMessageForCancel() {
        let cancel = SteamBottle.BottleError.componentCancelled(.vcRedistX86)
        let msg = SteamBottleViewModel.setupFailureMessage(cancel)
        #expect(msg.contains("cancelled"))
        #expect(msg.contains("Visual C++"))          // the component's title
        #expect(msg.contains("Set up again"))
        // Anything else is a plain failure.
        #expect(SteamBottleViewModel.setupFailureMessage(
            SteamBottle.BottleError.steamInstallFailed(1)).hasPrefix("Setup failed"))
    }

    @Test("setUp surfaces a 'Setup failed' status when the Steam install fails")
    func setUpFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))
        paths.createComponentMarkers()   // skip the non-Steam components so the queued results map cleanly
        fake.queueResult(ProcessResult(exitCode: 0))   // wineboot --init succeeds
        fake.queueResult(ProcessResult(exitCode: 0))   // wineserver -k (settle the boot server)
        fake.queueResult(ProcessResult(exitCode: 1))   // SteamSetup (user-guided) fails → steamInstallFailed

        await vm.setUp()

        #expect(vm.status.hasPrefix("Setup failed"))
        #expect(!vm.busy)
    }

    @Test("componentStatus asks the user to accept a license only for the user-guided components")
    func componentStatusText() {
        #expect(SteamBottleViewModel.componentStatus(.coreFonts).contains("Accept the license"))
        #expect(SteamBottleViewModel.componentStatus(.vcRedistX86).contains("Accept the license"))
        #expect(SteamBottleViewModel.componentStatus(.vcRedistX86).contains("Visual C++"))
        #expect(SteamBottleViewModel.componentStatus(.steamClient).contains("Accept the license"))
        #expect(!SteamBottleViewModel.componentStatus(.sourceHanSans).contains("Accept the license"))
        #expect(SteamBottleViewModel.componentStatus(.sourceHanSans).contains("Asian Fonts"))
    }

    @Test("launchSteam runs the bottle's Steam with the CEF/software-GL flags + env, silently on success")
    func launchSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))

        await vm.launchSteam()

        let call = try #require(fake.lastInvocation)
        #expect(call.detached)
        #expect(call.arguments.first == "explorer")
        #expect(call.arguments.contains("-cef-in-process-gpu"))
        #expect(call.environment["STEAM_CEF_COMMAND_LINE"]?.contains("--use-gl=swiftshader") == true)
        // Silent on success — no spinner (busy) and no lingering status label; Steam's window is the feedback.
        #expect(vm.status.isEmpty)
        #expect(!vm.busy)
    }

    @Test("resetLogin removes loginusers.vdf + ssfn tokens and reports cleared")
    func resetLogin() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        let client = paths.steamBottleClientDir
        let fm = FileManager.default
        try fm.createDirectory(at: client.appendingPathComponent("config"), withIntermediateDirectories: true)
        try "users".write(to: client.appendingPathComponent("config/loginusers.vdf"), atomically: true, encoding: .utf8)
        try "tok".write(to: client.appendingPathComponent("ssfn123"), atomically: true, encoding: .utf8)

        await vm.resetLogin()

        #expect(!fm.fileExists(atPath: client.appendingPathComponent("config/loginusers.vdf").path))
        #expect(!fm.fileExists(atPath: client.appendingPathComponent("ssfn123").path))
        #expect(vm.status.contains("Cleared"))
        #expect(!vm.busy)
    }
}
