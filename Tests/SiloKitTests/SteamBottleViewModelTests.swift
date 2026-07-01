import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("SteamBottleViewModel")
struct SteamBottleViewModelTests {

    private func make(_ tmp: TempDir) -> (SteamBottleViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let session = SteamClientSession(
            bottle: bottle, orchestrator: LaunchOrchestrator(runner: fake, linker: GraphicsLinker()))
        session.readinessTimeout = 0
        let vm = SteamBottleViewModel(bottle: bottle, session: session)
        return (vm, fake, paths)
    }

    @Test("steamInstalled is a cache: refreshInstalled() probes off-main; setUp sets it + fires the hook")
    func steamInstalledCache() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        #expect(!vm.steamInstalled)

        try FileManager.default.createDirectory(
            at: paths.steamBottleClientDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.steamBottleExe.path, contents: Data())
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

    @Test("setUp installs Steam into the bottle and reports success")
    func setUpSuccess() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))

        await vm.setUp()

        #expect(fake.invocations.contains { $0.arguments == ["wineboot", "--init"] })
        let install = try #require(fake.invocations.last { $0.arguments.last == "/S" })
        #expect(install.arguments.last == "/S")
        #expect(vm.status.contains("Steam installed"))
        #expect(!vm.busy)
    }

    @Test("setUp surfaces a 'Setup failed' status when the silent install fails")
    func setUpFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)
        FakeURLProtocol.stub(Silo.steamInstallerURL.absoluteString, data: Data("installer".utf8))
        vm.updateWine(URL(fileURLWithPath: "/w/wine64"))
        fake.queueResult(ProcessResult(exitCode: 0))   // wineboot --init succeeds
        fake.queueResult(ProcessResult(exitCode: 0))   // wineserver -k (settle the boot server)
        fake.queueResult(ProcessResult(exitCode: 1))   // SteamSetup.exe /S fails → steamInstallFailed

        await vm.setUp()

        #expect(vm.status.hasPrefix("Setup failed"))
        #expect(!vm.busy)
    }

    @Test("launchSteam runs the bottle's Steam with the CEF/software-GL flags + env and reports launch")
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
        #expect(vm.status.contains("Launched Steam"))
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
