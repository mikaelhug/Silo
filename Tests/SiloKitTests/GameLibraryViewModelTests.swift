import Foundation
import Testing
@testable import SiloKit

@MainActor
@Suite("GameLibraryViewModel")
struct GameLibraryViewModelTests {

    private func make(_ tmp: TempDir, wine: Bool = true)
        -> (GameLibraryViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig()
        if wine { backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64") }
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath)
        session.readinessTimeout = 0   // no readiness wait for the (fake) Steam in tests
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))
        return (vm, fake, paths)
    }

    /// Mark the bottle's Steam as installed (so the library is "ready").
    private func installSteam(_ paths: AppPaths) throws {
        let fm = FileManager.default
        let client = paths.steamBottleClientDir
        try fm.createDirectory(at: client, withIntermediateDirectories: true)
        fm.createFile(atPath: paths.steamBottleExe.path, contents: Data())
        // A WARMED client (steamui.dll + a CEF webhelper) — what steamReady now keys on, not the bootstrapper.
        fm.createFile(atPath: client.appendingPathComponent("steamui.dll").path, contents: Data())
        let cef = paths.steamBottleCEFDir.appendingPathComponent("cef.win7x64")
        try fm.createDirectory(at: cef, withIntermediateDirectories: true)
        fm.createFile(atPath: cef.appendingPathComponent("steamwebhelper.exe").path, contents: Data())
    }

    /// Simulate the bottle Steam's readiness by writing (or clearing) its `ActiveProcess` pid in `user.reg` —
    /// the exact signal `SteamClientSession.isRunning` now reads (Silo no longer tracks a client PID).
    private func setSteamReady(_ paths: AppPaths, _ ready: Bool) throws {
        try FileManager.default.createDirectory(at: paths.steamBottle, withIntermediateDirectories: true)
        let pid = ready ? "00001092" : "00000000"
        let text = #"[Software\\Valve\\Steam\\ActiveProcess]"# + "\n\"pid\"=dword:\(pid)\n"
        try text.write(to: SteamReadiness.userReg(prefix: paths.steamBottle),
                       atomically: true, encoding: .utf8)
    }

    /// Write a game manifest into the bottle's Steam library.
    private func writeManifest(_ paths: AppPaths, _ acf: String, appID: Int) throws {
        let steamapps = paths.steamBottleClientDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try acf.write(to: steamapps.appendingPathComponent("appmanifest_\(appID).acf"),
                      atomically: true, encoding: .utf8)
    }

    private func installedGame(_ paths: AppPaths, appID: Int, name: String, dir: String) throws -> SteamApp {
        let common = paths.steamBottleClientDir.appendingPathComponent("steamapps/common/\(dir)")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: common.appendingPathComponent("\(dir).exe").path, contents: Data("MZ".utf8))
        return SteamApp(appID: appID, name: name, installDir: dir,
                        stateFlags: .fullyInstalled, sizeOnDisk: 100, libraryPath: paths.steamBottleClientDir)
    }

    /// Bounded wait for the status auto-dismiss timer (a main-actor hop after a real sleep) to land.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A library VM with BOTH runtimes configured (real base wine + DXMT source trees so the DXMT variant can
    /// clone/overlay), + its fake runner + paths — for exercising the Automatic backend routing.
    private func makeDXMTReady(_ tmp: TempDir, i386: Bool = true)
        throws -> (GameLibraryViewModel, FakeProcessRunner, AppPaths) {
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        let wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("wine/lib/wine/x86_64-windows"); try tmp.makeDir("wine/lib/wine/x86_64-unix")
        let dxmtLib = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        if i386 { try tmp.makeDir("dxmt/lib/wine/i386-windows") }   // both ABIs → a 32-bit game may route to DXMT
        for m in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(m)", "DXMT")
            if i386 { try tmp.write("dxmt/lib/wine/i386-windows/\(m)", "DXMT32") }
        }
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix"); try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WM")
        var backend = BackendConfig(); backend.wineBinaryPath = wine; backend.dxmtLibDirPath = dxmtLib
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath); session.readinessTimeout = 0
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))
        return (vm, fake, paths)
    }

    /// A Steam game whose install dir holds a PE `game.exe` of the given COFF machine (0x014c = 32-bit,
    /// 0x8664 = 64-bit) — just enough header for `WindowsExecutable.machine`.
    private func installedGamePE(
        _ paths: AppPaths, appID: Int, name: String, dir: String, machine: UInt16) throws -> SteamApp {
        let common = paths.steamBottleClientDir.appendingPathComponent("steamapps/common/\(dir)")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        var b = [UInt8](repeating: 0, count: 0x50)
        b[0] = 0x4D; b[1] = 0x5A; b[0x3C] = 0x40                        // "MZ", e_lfanew = 0x40
        b[0x40] = 0x50; b[0x41] = 0x45                                  // "PE\0\0"
        b[0x44] = UInt8(machine & 0xFF); b[0x45] = UInt8(machine >> 8)  // COFF Machine
        FileManager.default.createFile(
            atPath: common.appendingPathComponent("game.exe").path, contents: Data(b))
        return SteamApp(appID: appID, name: name, installDir: dir,
                        stateFlags: .fullyInstalled, sizeOnDisk: 100, libraryPath: paths.steamBottleClientDir)
    }

    /// The persisted graphics choice for a Steam game (reads config.json back).
    private func persistedGraphics(_ paths: AppPaths, _ appID: Int) async -> GraphicsChoice {
        await ConfigStore(paths: paths).load().config(for: appID).graphics
    }

    @Test("load discovers games installed in the bottle's Steam library")
    func loadsInstalledGames() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try installSteam(paths)
        try writeManifest(paths, #""AppState" { "appid" "220" "name" "HL2" "StateFlags" "4" "installdir" "HL2" "LastOwner" "76561197960287930" "SizeOnDisk" "12000000" }"#, appID: 220)
        await vm.load()
        #expect(vm.loadState == .loaded)
        #expect(vm.games.map(\.appID) == [220])
    }

    @Test("steamReady is a cache: stale until load() re-probes off-main")
    func steamReadyCacheRefreshes() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        await vm.load()
        #expect(vm.loadState == .notReady && !vm.steamReady)
        try installSteam(paths)
        #expect(!vm.steamReady)          // the cache — nothing probed the disk yet
        await vm.load()
        #expect(vm.steamReady)
        #expect(vm.loadState == .empty)  // ready, no games installed yet
    }

    @Test("an unreadable Steam library surfaces a status while manual games still keep the library up")
    func unreadableBottleSurfacesStatus() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)

        // Steam installed but its steamapps can't be listed (permissions).
        try installSteam(paths)
        let steamapps = paths.steamBottleClientDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: steamapps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamapps.path)
        }
        // A manual game exists → the read failure surfaces as a status, not the load's .error state.
        let exe = try tmp.write("Games/X/x.exe", "MZ")
        _ = try #require(await vm.addManualGame(name: "X", executable: exe))

        await vm.load()
        #expect(vm.loadState == .loaded)                    // the manual game keeps the library up
        #expect(vm.games.isEmpty)                           // the Steam library couldn't be read
        #expect(vm.statusMessage?.contains("Steam library") == true)
    }

    @Test("load → .error when the ONLY bottle's library is unreadable and there's nothing else to show")
    func unreadableOnlyBottleIsLoadError() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try installSteam(paths)
        let steamapps = paths.steamBottleClientDir.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: steamapps.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: steamapps.path)
        }
        await vm.load()
        guard case .error(let message) = vm.loadState else {
            Issue.record("expected .error, got \(vm.loadState)")
            return
        }
        #expect(message.contains("isn't readable"))
    }

    @Test("removeManual surfaces a bottle-deletion failure instead of silently leaking the dir")
    func removeManualSurfacesDeleteFailure() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        let game = ManualGame(id: UUID(), name: "G", executablePath: URL(fileURLWithPath: "/g/g.exe"))
        let bottle = paths.manualBottle(game.id)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let parent = bottle.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }
        await vm.removeManual(game)
        #expect(vm.statusMessage?.contains("remove it in Finder") == true)
        #expect(!vm.manualGames.contains { $0.id == game.id })   // still removed from the library
    }

    @Test("resolveMessage maps every launch-stack error to actionable text")
    func resolveMessageTable() {
        let cases: [(Error, String)] = [
            (BottleResolver.ResolveError.backendNotConfigured(.dxmt), "isn't installed"),
            (BottleResolver.ResolveError.wineNotConfigured, "No Wine configured."),
            (LaunchOrchestrator.LaunchError.wineNotConfigured, "No Wine configured."),
            (WinePrefixProvisioner.ProvisionError.wineNotConfigured, "No Wine configured."),
            (LaunchOrchestrator.LaunchError.executableNotFound(URL(fileURLWithPath: "/g/Game")), "/g/Game"),
            (WinePrefixProvisioner.ProvisionError.winebootFailed(1), "initialize the game's Wine bottle"),
            (RuntimeVariants.VariantError.cloneFailed(URL(fileURLWithPath: "/rt-dxmt"), 28), "disk space"),
            (GraphicsLinker.LinkError.sourceMissing(URL(fileURLWithPath: "/dxmt/lib")), "re-download"),
        ]
        for (error, expected) in cases {
            #expect(GameLibraryViewModel.resolveMessage(error).contains(expected),
                    "\(error) → \(GameLibraryViewModel.resolveMessage(error))")
        }
    }

    @Test("launches are refused while a bottles move is in progress")
    func launchRefusedWhileRelocating() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        vm.isRelocating = { true }                        // a bottles move is underway
        await vm.play(game)
        #expect(vm.statusMessage?.contains("moving your bottles") == true)
        #expect(!fake.invocations.contains { $0.detached })   // nothing spawned into a prefix being moved
    }

    @Test("provisioning a manual bottle is refused during a bottles move (no write into the moving prefix)")
    func provisionRefusedWhileRelocating() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        await vm.load()
        vm.isRelocating = { true }                            // a bottles move is underway
        let exe = try tmp.write("Games/X/x.exe", "MZ")
        let added = await vm.addManualGame(name: "X", executable: exe)
        #expect(added == nil)                                                             // refused
        #expect(!fake.invocations.contains { $0.arguments == ["wineboot", "--init"] })   // never provisioned
        #expect(vm.statusMessage?.contains("moving your bottles") == true)
    }

    @Test("load → notReady when the bottle has no Steam installed")
    func notReadyWithoutSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, _) = make(tmp)
        await vm.load()
        #expect(vm.loadState == .notReady)
    }

    @Test("play launches the game co-resident in the bottle prefix")
    func playInBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)
        // The game was launched detached with WINEPREFIX forced to the shared bottle.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && ($0.arguments.first?.hasSuffix("HL2.exe") ?? false)
        })
        // Silo does NOT track or SIGTERM the launched game — it runs detached and outlives the app (like
        // CrossOver). No stop path, no taskkill.
        #expect(fake.terminatedPIDs.isEmpty)
        #expect(!fake.invocations.contains { $0.arguments.first == "taskkill" })
    }

    @Test("Automatic routes a 32-bit Steam game to DXMT in the shared bottle")
    func autoRoutes32BitToDXMT() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = try makeDXMTReady(tmp)
        try installSteam(paths)
        let game = try installedGamePE(paths, appID: 220, name: "OC2", dir: "OC2", machine: 0x014c)

        await vm.play(game)

        // The GAME spawn (not the Steam client) runs in the SHARED Steam prefix on the DXMT variant runtime.
        let spawn = try #require(fake.invocations.last {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && ($0.arguments.first?.hasSuffix("game.exe") ?? false)
        })
        #expect(spawn.environment["WINELOADER"]?.contains("/wine-dxmt/bin/wine64") == true)
        #expect(spawn.environment["WINEDLLOVERRIDES"] == "d3d10core,d3d11,dxgi,winemetal=b")
        // The DXMT prefix-loader seeded winemetal.dll into the shared Steam prefix (needed for DXMT to load).
        let wm = paths.steamBottle.appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        #expect(FileManager.default.fileExists(atPath: wm.path))
    }

    @Test("A 32-bit game is refused when the installed DXMT has no i386 build (no silent black screen)")
    func refuses32BitWhenDXMTLacksI386() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = try makeDXMTReady(tmp, i386: false)   // DXMT installed, 64-bit-only
        try installSteam(paths)
        let game = try installedGamePE(paths, appID: 220, name: "OC2", dir: "OC2", machine: 0x014c)

        await vm.play(game)

        #expect(vm.statusMessage?.contains("32-bit DXMT build") == true)   // honest refusal, steers to update
        #expect(!fake.invocations.contains {                               // never spawned the game
            $0.detached && ($0.arguments.first?.hasSuffix("game.exe") ?? false)
        })
    }

    @Test("Automatic reactively remembers DXMT after a 64-bit game fails under GPTK")
    func autoReactiveSwitchToDXMT() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = try makeDXMTReady(tmp)
        try installSteam(paths)
        let game = try installedGamePE(paths, appID: 220, name: "HL2", dir: "HL2", machine: 0x8664)  // 64-bit → GPTK
        // The game writes the GPTK-didn't-engage signature to its log as it spawns.
        let log = paths.log(forAppID: 220)
        fake.onRun = { inv in
            guard inv.detached, inv.logURL == log, let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data(#"Assertion failed: (GFXTHandle && "Failed to dlopen D3DMetal")"#.utf8))
            try? h.close()
        }

        await vm.play(game)   // launches on GPTK; the monitor detects the failure and persists DXMT

        for _ in 0..<200 where await persistedGraphics(paths, 220) != .dxmt { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await persistedGraphics(paths, 220) == .dxmt)          // Automatic learned: use DXMT next time
        #expect(vm.statusMessage?.contains("use DXMT") == true)
    }

    @Test("the status line self-clears after its visible window (a stale 'Launched …' doesn't linger)")
    func statusAutoDismisses() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        vm.statusVisibleDuration = .milliseconds(20)   // keep the test fast; real app uses seconds
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)
        #expect(vm.statusMessage == "Launched HL2.")   // shown right after the action

        // No further action: the message self-clears once its window elapses.
        try await waitUntil { vm.statusMessage == nil }
        #expect(vm.statusMessage == nil)
    }

    @Test("a fresh status resets the dismissal so the prior message's timer can't wipe it")
    func statusTimerResetsOnNewMessage() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        vm.statusVisibleDuration = .milliseconds(120)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)                            // arms a dismissal for "Launched HL2."
        // Second action → new status ("Removed …"), which must cancel the first message's timer.
        await vm.removeManual(ManualGame(name: "G", executablePath: URL(fileURLWithPath: "/g/g.exe")))
        let second = try #require(vm.statusMessage)
        // Wait well past the FIRST message's window but short of the second's: a stale timer must not have
        // cleared the newer message.
        try await Task.sleep(for: .milliseconds(40))
        #expect(vm.statusMessage == second)
    }

    @Test("play is refused while a self-update is installing (it relaunches Silo — a game would be orphaned)")
    func playRefusedDuringUpdate() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        vm.isUpdating = { true }                       // an inline update is downloading/installing

        await vm.play(game)

        #expect(vm.statusMessage?.lowercased().contains("update") == true)
        #expect(!fake.invocations.contains { $0.detached })   // nothing spawned (not even Steam)
    }

    @Test("manual games: add provisions an isolated bottle, play runs in it, remove deletes it")
    func manualGameLifecycle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        await vm.load()                                  // an empty Steam library
        #expect(vm.loadState == .empty)

        // The user points at an installed/portable .exe anywhere on disk.
        let exe = try tmp.write("Games/Cool/Cool.exe", "MZ")
        let game = try #require(await vm.addManualGame(name: "Cool Game", executable: exe))
        #expect(vm.manualGames.map(\.name) == ["Cool Game"])
        #expect(vm.loadState == .loaded)                 // a manual game makes the library non-empty
        // Adding provisioned the game's OWN bottle (wineboot --init), not the shared Steam bottle.
        #expect(fake.invocations.contains { $0.arguments == ["wineboot", "--init"] })

        await vm.playManual(game)
        let ownBottle = paths.manualBottle(game.id).path
        #expect(ownBottle != paths.steamBottle.path)     // isolated, NOT the shared bottle
        // Spawned detached into its OWN bottle prefix, with the absolute exe — and NO Steam cold-start.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == ownBottle
                && $0.arguments.first == exe.path
        })
        #expect(!fake.invocations.contains { $0.arguments.first?.hasSuffix("steam.exe") ?? false })
        #expect(fake.terminatedPIDs.isEmpty)             // detached — Silo never SIGTERMs a launched game

        // The game's bottle isn't live in this test (no real wineserver socket), so remove proceeds.
        await vm.removeManual(game)
        #expect(vm.manualGames.isEmpty)
        #expect(vm.loadState == .empty)                  // empty again once both lists are empty
    }

    @Test("discardManualBottle deletes a provisioned-but-unsaved bottle (Add sheet cancel)")
    func discardDraftBottle() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        let id = UUID()
        // Simulate wineboot creating the bottle on disk.
        fake.onRun = { inv in
            guard inv.arguments == ["wineboot", "--init"] else { return }
            let layout = PrefixLayout(prefix: paths.manualBottle(id))
            try? FileManager.default.createDirectory(at: layout.driveC, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: layout.systemReg.path, contents: Data())
        }
        #expect(await vm.ensureManualBottle(id))
        #expect(FileManager.default.fileExists(atPath: paths.manualBottle(id).path))

        await vm.discardManualBottle(id)
        #expect(!FileManager.default.fileExists(atPath: paths.manualBottle(id).path))
    }

    @Test("a DXMT manual game launches on the cloned DXMT variant runtime with DXMT's builtin overrides")
    func manualGameDXMTRoutesToVariantRuntime() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())

        // Real base wine tree + DXMT source tree so the resolver can clone the variant + overlay DXMT.
        let wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        let dxmtLib = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        for m in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(m)", "DXMT:\(m)")
        }
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WINEMETAL")

        var backend = BackendConfig()
        backend.wineBinaryPath = wine
        backend.dxmtLibDirPath = dxmtLib
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath); session.readinessTimeout = 0
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))

        let exe = try tmp.write("Games/Old/old.exe", "MZ")
        let game = try #require(await vm.addManualGame(name: "Old", executable: exe, backend: .dxmt))
        #expect(game.backend == .dxmt)
        await vm.playManual(game)

        let spawn = try #require(fake.invocations.last { $0.detached })
        // Launched via the game's Dock-naming `.app` wrapper (so the tile reads "Old", not "wine")…
        #expect(spawn.executable.path.hasSuffix("DockApps/manual-\(game.id.uuidString).app/Contents/MacOS/Old"))
        // …with the cloned DXMT runtime pinned via WINELOADER so wine still self-locates it.
        #expect(spawn.environment["WINELOADER"]?.contains("/wine-dxmt/bin/wine64") == true)
        #expect(spawn.environment["WINEDLLOVERRIDES"] == "d3d10core,d3d11,dxgi,winemetal=b")
        #expect(spawn.environment["WINEPREFIX"] == paths.manualBottle(game.id).path)   // its own isolated bottle
    }

    @Test("addManualGame defaults the name to the exe filename and persists across a reload")
    func manualGameDefaultNameAndPersistence() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, _, paths) = make(tmp)
        try installSteam(paths)
        let exe = try tmp.write("Portable/Witness.exe", "MZ")
        _ = await vm.addManualGame(name: "   ", executable: exe)   // blank → default to filename
        #expect(vm.manualGames.first?.name == "Witness")

        await vm.load()                                  // reload from config.json
        #expect(vm.manualGames.map(\.name) == ["Witness"])   // persisted
    }

    @Test("two games launched at once start the bottle Steam only once")
    func concurrentPlayLaunchesSteamOnce() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        async let pa: Void = vm.play(a)
        async let pb: Void = vm.play(b)
        _ = await (pa, pb)

        // The Steam client launch is the virtual desktop + CEF flags — there must be exactly ONE, not one per game.
        let steamLaunches = fake.invocations.filter {
            $0.arguments.first == "explorer" && $0.arguments.contains("-cef-in-process-gpu")
        }
        #expect(steamLaunches.count == 1)
    }

    @Test("settings 'Launch Steam' then a game Play share ONE tracked client (no double-spawn)")
    func sharedSteamClientNoDoubleSpawn() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig(); backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")
        // ONE shared session — exactly how AppEnvironment wires the Library + the settings pane.
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.updateWine(backend.wineBinaryPath); session.readinessTimeout = 0
        let library = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))
        let settings = SteamBottleViewModel(bottle: bottle, session: session)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await settings.launchSteam()   // brings Steam up (via the shared session)
        try setSteamReady(paths, true) // Steam registered → play reuses it, not a SECOND client
        await library.play(game)

        #expect(steamCEFLaunches(fake) == 1)   // ONE client — shared across both view models
    }

    @Test("play is a no-op without a configured Wine backend")
    func playNeedsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp, wine: false)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(!fake.invocations.contains { $0.detached })   // nothing launched
    }

    @Test("uninstall asks the bottle's Steam to remove the game")
    func uninstallViaSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.uninstall(game)
        let call = try #require(fake.lastInvocation)
        #expect(call.arguments.contains("steam://uninstall/220"))
    }

    /// Count the bottle-Steam (CEF) launches recorded by the runner.
    private func steamCEFLaunches(_ fake: FakeProcessRunner) -> Int {
        fake.invocations.filter {
            $0.arguments.first == "explorer" && $0.arguments.contains("-cef-in-process-gpu")
        }.count
    }

    @Test("a second Play with Steam already up does not relaunch Steam")
    func secondPlayReusesRunningSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        await vm.play(a)                 // cold-starts Steam (first spawn) + launches A
        #expect(steamCEFLaunches(fake) == 1)
        try setSteamReady(paths, true)   // Steam registered its ActiveProcess pid → isRunning == true
        await vm.play(b)                 // Steam ready → reused, NOT relaunched
        #expect(steamCEFLaunches(fake) == 1)
    }

    @Test("a Play after the bottle Steam exits cold-starts Steam again")
    func playAfterSteamExitRestartsSteam() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let a = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let b = try installedGame(paths, appID: 570, name: "Dota", dir: "Dota")

        await vm.play(a)
        try setSteamReady(paths, true)              // Steam came up (registered ActiveProcess)
        #expect(steamCEFLaunches(fake) == 1)

        try setSteamReady(paths, false)             // Steam exited → its ActiveProcess pid is cleared
        await vm.play(b)                            // not ready → cold-starts Steam again
        #expect(steamCEFLaunches(fake) == 2)
    }

    @Test("play surfaces a launch failure to statusMessage without sticking the game busy/running")
    func playLaunchFailureSurfacesStatus() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)                       // past the wine/steam guards
        // A game whose install dir has NO exe → orchestrator.launchInBottle throws executableNotFound.
        let game = SteamApp(appID: 220, name: "HL2", installDir: "Nope",
                            stateFlags: .fullyInstalled, sizeOnDisk: 100,
                            libraryPath: paths.steamBottleClientDir)

        await vm.play(game)

        #expect(!vm.isBusy(game))                     // defer cleared busyGames
        #expect(vm.statusMessage?.contains("HL2") == true)   // the catch surfaced "<name>: <error>"
        // The game itself was never spawned detached (resolution failed before spawn).
        #expect(!fake.invocations.contains {
            $0.detached && ($0.arguments.first?.hasSuffix("Nope.exe") ?? false)
        })
    }

    @Test("play aborts with a status (and never spawns the game) when the Steam client can't start")
    func playAbortsWhenSteamCantStart() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        var backend = BackendConfig()
        backend.wineBinaryPath = URL(fileURLWithPath: "/w/wine64")   // backend configured → play's guard passes
        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.readinessTimeout = 0
        // Deliberately leave the session WITHOUT a wine binary → bottle.launchSteam throws → ensureRunning false.
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)

        #expect(vm.statusMessage?.contains("Steam") == true)         // surfaced WHY, not a misleading "Launched"
        #expect(!fake.invocations.contains { $0.detached })          // nothing spawned — not even the game
    }

    @Test("play surfaces a GPTK-fallback warning when the launch log shows a wined3d fallback")
    func playSurfacesGraphicsFallback() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        // Simulate the game writing a wined3d-fallback signature to its log — appended when it spawns, i.e.
        // AFTER Silo writes the launch-context header (spawn writes the header, then spawnDetached runs and
        // the onRun hook fires, exactly as a failing game's stderr would append). The monitor reads the tail
        // on start, so the warning surfaces deterministically (overriding "Launched"), proving a silent
        // GPTK→wined3d fallback can no longer hide behind "Launched".
        let log = paths.log(forAppID: 220)
        fake.onRun = { inv in
            guard inv.detached, inv.logURL == log, let handle = try? FileHandle(forWritingTo: log) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(#"Assertion failed: (GFXTHandle && "Failed to dlopen D3DMetal")"#.utf8))
            try? handle.close()
        }

        await vm.play(game)

        #expect(vm.statusMessage?.contains("GPTK") == true)          // fallback surfaced, not a silent "Launched"
        #expect(vm.statusMessage?.contains("Launched") != true)
        // Honest: it doesn't claim a working "fallback". DXMT isn't configured in this test, so the Automatic
        // reactive switch can't fire — the message steers the user to set DXMT up.
        #expect(vm.statusMessage?.contains("fallback graphics") != true)
        #expect(vm.statusMessage?.contains("couldn't drive this game's graphics") == true)
        #expect(vm.statusMessage?.contains("Set up DXMT") == true)
    }

    @Test("graphicsFallbackMessage steers to DXMT only when DXMT could help, adapting to readiness")
    func graphicsFallbackMessageBranches() {
        typealias VM = GameLibraryViewModel
        // GPTK, DXMT installed + could help → switch this game's graphics to DXMT.
        let gptkReady = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, dxmtAvailable: true, dxmtMightHelp: true)
        #expect(gptkReady.contains("Switch this game's graphics to DXMT"))
        // GPTK, DXMT not installed → set DXMT up first.
        let gptkNotReady = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, dxmtAvailable: false, dxmtMightHelp: true)
        #expect(gptkNotReady.contains("Set up DXMT in Settings → DXMT first"))
        // GPTK, DXMT can't help this game (D3D12 / D3D9-only) → NO false DXMT steer.
        let gptkNoHelp = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, dxmtAvailable: true, dxmtMightHelp: false)
        #expect(gptkNoHelp.contains("couldn't drive this game's graphics"))
        #expect(!gptkNoHelp.contains("DXMT"))
        // DXMT backend → names DXMT, points at Settings.
        let dxmt = VM.graphicsFallbackMessage(name: "OC2", backend: .dxmt, dxmtAvailable: true, dxmtMightHelp: true)
        #expect(dxmt.contains("DXMT couldn't drive this game's graphics") && dxmt.contains("Settings → DXMT"))
        // None of them pretends graphics are "running on fallback graphics".
        for m in [gptkReady, gptkNotReady, gptkNoHelp, dxmt] {
            #expect(m.hasPrefix("OC2: "))
            #expect(!m.contains("running on fallback graphics"))
        }
    }

    @Test("quitting does NOT kill launched games or Steam (they run detached)")
    func launchesAreNeverKilled() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let hl2 = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let tf2 = try installedGame(paths, appID: 440, name: "TF2", dir: "TF2")
        await vm.play(hl2)
        await vm.play(tf2)

        // There is no app-quit teardown and no stop path: nothing Silo launched is ever SIGTERM'd or
        // taskkilled — games (and Steam) outlive the launcher, exactly like CrossOver.
        #expect(fake.terminatedPIDs.isEmpty)
        #expect(!fake.invocations.contains { $0.arguments.first == "taskkill" })
    }
}
