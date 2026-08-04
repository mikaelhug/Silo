import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("Launch guards")
struct LaunchGuardTests {

    /// A config written by a NEWER Silo (an unknown backend/sync value) must degrade, never throw — a throw
    /// propagates out of AppState and ConfigStore returns a FRESH one, wiping every runtime path, per-game
    /// setting and manual game, with the next save overwriting the file.
    @Test("an unknown enum value in config.json degrades instead of wiping the document")
    func unknownEnumValuesDoNotWipeConfig() throws {
        let json = """
        {"appID":220,"graphics":"future_backend","learnedBackend":"future_backend",
         "envFlags":{"syncMode":"future_sync","metalBackend":"future_metal"}}
        """
        let cfg = try JSONDecoder().decode(GameConfig.self, from: Data(json.utf8))
        #expect(cfg.appID == 220)                 // the document survived
        #expect(cfg.graphics == .auto)            // unknown choice → Automatic
        #expect(cfg.learnedBackend == nil)        // unknown hint → dropped
        #expect(cfg.envFlags.syncMode == .msync)  // unknown sync → the safe default
        #expect(cfg.envFlags.metalBackend == .auto)
    }

    /// REGRESSION — 0.4.5 shipped broken. `play` gated EVERY launch on a guessed "is signed in" marker (an
    /// `ssfn*` file in the Steam client root). Real logged-in Steam installs need not have one — the
    /// reporter's had none — so the gate refused every launch with "sign in to Steam", and the unit test that
    /// "covered" it merely asserted my invented fixture back to me.
    ///
    /// The durable lesson, and what this test pins: **a pre-launch gate built on an inferred signal must
    /// fail OPEN.** A warmed bottle carrying no login marker of any kind still has to launch.
    @Test("a bottle with no login marker still launches — launch gates never fail closed on a guess")
    func launchIsNotBlockedByAnAbsentLoginMarker() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig(); backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath); session.readinessTimeout = 0
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))

        // A warmed client — and deliberately NO ssfn / login marker of any kind.
        let fm = FileManager.default
        let client = paths.steamBottleClientDir
        try fm.createDirectory(at: client, withIntermediateDirectories: true)
        fm.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        fm.createFile(atPath: client.appendingPathComponent("steamui.dll").path, contents: Data())
        let cef = paths.steamBottleCEFDir.appendingPathComponent("cef.win7x64")
        try fm.createDirectory(at: cef, withIntermediateDirectories: true)
        fm.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())
        let common = client.appendingPathComponent("steamapps/common/HL2")
        try fm.createDirectory(at: common, withIntermediateDirectories: true)
        fm.createFile(atPath: common.appendingPathComponent("HL2.exe").path, contents: Data("MZ".utf8))
        let game = SteamApp(appID: 220, name: "HL2", installDir: "HL2",
                            stateFlags: .fullyInstalled, sizeOnDisk: 100, libraryPath: client)

        await vm.play(game)

        #expect(vm.statusMessage?.localizedCaseInsensitiveContains("sign in") != true)
        #expect(fake.invocations.contains { $0.detached && ($0.arguments.first?.hasSuffix("HL2.exe") ?? false) })
    }
}
