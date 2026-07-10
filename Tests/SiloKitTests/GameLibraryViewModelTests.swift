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

    @Test("a DXMT manual game's shortcut launches on the DXMT variant runtime (resolver-routed)")
    func dxmtManualShortcutUsesVariantRuntime() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let paths = AppPaths(supportDir: tmp.url.appendingPathComponent("Silo"))
        let fake = FakeProcessRunner()
        let bottle = SteamBottle(runner: fake, session: FakeURLProtocol.makeSession(), paths: paths)
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())

        // Real base wine + DXMT source so the resolver can clone the variant + overlay.
        let wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("wine/lib/wine/x86_64-windows"); try tmp.makeDir("wine/lib/wine/x86_64-unix")
        let dxmtLib = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        for m in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(m)", "DXMT")
        }
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WM")
        var backend = BackendConfig(); backend.wineBinaryPath = wine; backend.dxmtLibDirPath = dxmtLib

        let session = SteamClientSession(bottle: bottle, orchestrator: orchestrator)
        session.readinessTimeout = 0
        let vm = GameLibraryViewModel(
            bottle: bottle, discovery: DiscoveryEngine(), orchestrator: orchestrator,
            configStore: ConfigStore(paths: paths), paths: paths, backend: backend, session: session,
            provisioner: WinePrefixProvisioner(runner: fake))

        let game = ManualGame(name: "OldGame",
                              executablePath: tmp.url.appendingPathComponent("game/old.exe"),
                              backend: .dxmt)
        let dest = try tmp.makeDir("shortcut-dest")
        let app = try #require(await vm.makeShortcut(for: game, into: dest))

        let script = try String(
            contentsOf: app.appendingPathComponent("Contents/MacOS/launch"), encoding: .utf8)
        #expect(script.contains("wine-dxmt"))       // the cloned DXMT variant runtime, not the base wine
        #expect(script.contains("winemetal=b"))     // DXMT's builtin override set…
        #expect(!script.contains("d3d12"))          // …and never GPTK's (which includes d3d12)
        // The shortcut ALSO seeds winemetal.dll into the game's own prefix (system32). Without it a DXMT
        // game launched from the standalone .app — which execs wine with no launch pipeline — can't load the
        // winemetal builtin and silently falls back to wined3d → graphics-init failure.
        let winemetal = paths.manualBottle(game.id)
            .appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        #expect(FileManager.default.fileExists(atPath: winemetal.path))
    }

    /// A minimal valid PE with the given COFF machine type (0x014c = i386/32-bit, 0x8664 = amd64).
    private func makePE(machine: UInt16, peOffset: Int = 0x40) -> Data {
        var data = Data(count: peOffset + 6)
        data[0] = 0x4D; data[1] = 0x5A                                   // "MZ"
        data[0x3C] = UInt8(peOffset & 0xFF); data[0x3D] = UInt8((peOffset >> 8) & 0xFF)
        data[peOffset] = 0x50; data[peOffset + 1] = 0x45                 // "PE"
        data[peOffset + 4] = UInt8(machine & 0xFF); data[peOffset + 5] = UInt8(machine >> 8)
        return data
    }

    @Test("makeShortcut refuses a 32-bit game on GPTK (would launch to a wined3d-fallback failure, no steer)")
    func makeShortcutRefuses32BitGPTK() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, _) = make(tmp)                       // GPTK-configured
        let exe = tmp.url.appendingPathComponent("old32/game.exe")
        try FileManager.default.createDirectory(
            at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePE(machine: 0x014c).write(to: exe)          // a real i386 (32-bit) PE
        let game = ManualGame(name: "Old32", executablePath: exe, backend: .gptk)
        let dest = try tmp.makeDir("dest")

        let app = await vm.makeShortcut(for: game, into: dest)

        #expect(app == nil)                                 // refused up front, like playManual
        #expect(vm.statusMessage?.contains("32-bit") == true)
        #expect(!fake.invocations.contains { $0.arguments.contains("wineboot") })   // no prefix work done
    }

    @Test("resolveMessage maps every launch-stack error to actionable text")
    func resolveMessageTable() {
        let cases: [(Error, String)] = [
            (BottleResolver.ResolveError.backendNotConfigured(.dxmt), "isn't installed"),
            (BottleResolver.ResolveError.wineNotConfigured, "No Wine configured."),
            (LaunchOrchestrator.LaunchError.wineNotConfigured, "No Wine configured."),
            (WinePrefixProvisioner.ProvisionError.wineNotConfigured, "No Wine configured."),
            (LaunchOrchestrator.LaunchError.executableNotFound(URL(fileURLWithPath: "/g/Game")), "/g/Game"),
            (WinePrefixProvisioner.ProvisionError.winebootFailed(1), "wineboot exited 1"),
            (RuntimeVariants.VariantError.cloneFailed(URL(fileURLWithPath: "/rt-dxmt"), 28), "disk space"),
            (GraphicsLinker.LinkError.sourceMissing(URL(fileURLWithPath: "/dxmt/lib")), "re-download"),
        ]
        for (error, expected) in cases {
            #expect(GameLibraryViewModel.resolveMessage(error).contains(expected),
                    "\(error) → \(GameLibraryViewModel.resolveMessage(error))")
        }
    }

    @Test("play is a no-op for a game that's already running (no relaunch)")
    func playNoOpWhenAlreadyRunning() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(vm.isRunning(game))
        let detachedBefore = fake.invocations.filter(\.detached).count

        await vm.play(game)                                                   // already running → no-op
        #expect(fake.invocations.filter(\.detached).count == detachedBefore)  // no new spawn
    }

    @Test("launches are refused while a bottles move is in progress")
    func launchRefusedWhileRelocating() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        vm.isRelocating = { true }                        // a bottles move is underway
        await vm.play(game)
        #expect(!vm.isRunning(game))
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
        #expect(vm.isRunning(game))
        // Steam cold-starts first (PID 4242), so the game loader is the next spawn (4243).
        let loaderPID = try #require(vm.pid(for: game))
        #expect(loaderPID == 4243)
        // The game was launched detached with WINEPREFIX forced to the shared bottle.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == paths.steamBottle.path
                && ($0.arguments.first?.hasSuffix("HL2.exe") ?? false)
        })

        await vm.stop(game)
        #expect(!vm.isRunning(game))
        // Stop SIGTERMs the launched loader (not just taskkill) — proving both halves of the contract.
        #expect(fake.terminatedPIDs.contains(loaderPID))
        // Stop also taskkills the game's image (in the bottle's msync wineserver) so a child/relauncher
        // isn't orphaned — without clobbering the co-resident Steam.
        #expect(fake.invocations.contains {
            $0.arguments == ["taskkill", "/F", "/IM", "HL2.exe"] && $0.environment["WINEMSYNC"] == "1"
        })
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

    /// Manifest + install dir for a Steam game with a specific exe basename (so two games can be made to
    /// share one — the `taskkill /IM` collision case).
    private func writeInstalledGame(
        _ paths: AppPaths, appID: Int, name: String, dir: String, exe: String) throws {
        try writeManifest(paths, #""AppState" { "appid" "\#(appID)" "name" "\#(name)" "StateFlags" "4" "installdir" "\#(dir)" "LastOwner" "76561197960287930" "SizeOnDisk" "12000000" }"#, appID: appID)
        let common = paths.steamBottleClientDir.appendingPathComponent("steamapps/common/\(dir)")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: common.appendingPathComponent(exe).path, contents: Data("MZ".utf8))
    }

    @Test("stop skips taskkill /IM when a co-resident sibling shares the exe basename, but fires it otherwise")
    func stopAvoidsSiblingImageCollision() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        // Two DIFFERENT Steam games in the SAME (GPTK) bottle whose exes share a basename.
        // Basenames differ only in CASE — wine's taskkill /IM matches case-insensitively, so this must
        // still be treated as a collision.
        try writeInstalledGame(paths, appID: 220, name: "A", dir: "GameA", exe: "Launcher.exe")
        try writeInstalledGame(paths, appID: 400, name: "B", dir: "GameB", exe: "launcher.exe")
        await vm.load()
        let a = try #require(vm.games.first { $0.appID == 220 })
        let b = try #require(vm.games.first { $0.appID == 400 })
        await vm.play(a)
        await vm.play(b)
        #expect(vm.isRunning(a) && vm.isRunning(b))
        let loaderA = try #require(vm.pid(for: a))

        // Stop A ("Launcher.exe") while B ("launcher.exe") is live: /IM matches case-insensitively and would
        // take B down too, so NO taskkill is issued at all (SIGTERM the loader only).
        await vm.stop(a)
        #expect(!vm.isRunning(a))
        #expect(fake.terminatedPIDs.contains(loaderA))                       // SIGTERM the loader still happens
        #expect(!fake.invocations.contains { $0.arguments.first == "taskkill" })   // but NO bystander-killing /IM

        // With A gone, B has no co-resident sharing its image — /IM is safe and fires.
        await vm.stop(b)
        #expect(fake.invocations.contains { $0.arguments == ["taskkill", "/F", "/IM", "launcher.exe"] })
    }

    @Test("play is refused while a self-update is installing (it relaunches Silo — a game would be orphaned)")
    func playRefusedDuringUpdate() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        vm.isUpdating = { true }                       // an inline update is downloading/installing

        await vm.play(game)

        #expect(!vm.isRunning(game))
        #expect(vm.statusMessage?.lowercased().contains("update") == true)
        #expect(!fake.invocations.contains { $0.detached })   // nothing spawned (not even Steam)
    }

    @Test("a game exiting on its own clears the running state")
    func gameExitClearsState() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(vm.isRunning(game))

        let pid = try #require(vm.pid(for: game))
        fake.setAlive(pid, false)   // simulate the game process exiting
        for _ in 0..<20 where vm.isRunning(game) { await Task.yield() }   // let the @MainActor handler run
        #expect(!vm.isRunning(game))
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
        #expect(vm.isRunning(game))
        let pid = try #require(vm.pid(for: game))
        let ownBottle = paths.manualBottle(game.id).path
        #expect(ownBottle != paths.steamBottle.path)     // isolated, NOT the shared bottle
        // Spawned detached into its OWN bottle prefix, with the absolute exe — and NO Steam cold-start.
        #expect(fake.invocations.contains {
            $0.detached && $0.environment["WINEPREFIX"] == ownBottle
                && $0.arguments.first == exe.path
        })
        #expect(!fake.invocations.contains { $0.arguments.first?.hasSuffix("steam.exe") ?? false })

        await vm.stopManual(game)
        #expect(!vm.isRunning(game))
        #expect(fake.terminatedPIDs.contains(pid))

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
        #expect(spawn.executable.path.contains("/wine-dxmt/bin/wine64"))   // the cloned DXMT runtime, not the base
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

        await settings.launchSteam()   // the formerly-untracked spawn path
        await library.play(game)       // previously this cold-started a SECOND Steam client

        #expect(steamCEFLaunches(fake) == 1)   // ONE client — shared + tracked across both view models
        #expect(library.isRunning(game))
    }

    @Test("play is a no-op without a configured Wine backend")
    func playNeedsWine() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp, wine: false)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        await vm.play(game)
        #expect(!vm.isRunning(game))
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

    @Test("uninstall is a no-op while the game is running")
    func uninstallNoOpWhileRunning() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let game = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")

        await vm.play(game)                          // launches the game → tracked as running
        #expect(vm.isRunning(game))

        await vm.uninstall(game)                      // guard !isRunning must short-circuit

        // No steam://uninstall URL was ever sent for a running game.
        #expect(!fake.invocations.contains { $0.arguments.contains("steam://uninstall/220") })
        #expect(vm.isRunning(game))                  // still running, untouched
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

        await vm.play(a)   // cold-starts Steam (first spawn, alive) + launches A
        await vm.play(b)   // Steam already up → isRunning short-circuit, NOT a relaunch
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
        #expect(steamCEFLaunches(fake) == 1)

        // ensureSteamRunning() runs before the game launch, so Steam is the FIRST detached spawn (PID 4242).
        // Kill it → the steamObserver nulls steamPID.
        #expect(fake.invocations.first { $0.detached }?.arguments.contains("-cef-in-process-gpu") == true)
        fake.setAlive(4242, false)
        // Let the @MainActor exit observer run (it nulls steamPID).
        for _ in 0..<50 { await Task.yield() }

        await vm.play(b)                            // steamPID nil now → cold-starts Steam again
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

        #expect(!vm.isRunning(game))                  // never tracked a PID
        #expect(!vm.isBusy(game))                     // defer cleared busyGames
        #expect(vm.pid(for: game) == nil)
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

        #expect(!vm.isRunning(game))
        #expect(vm.pid(for: game) == nil)
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
        // Honest: it doesn't claim a working "fallback", and (Steam is GPTK-only now) it admits the class
        // isn't supported in the Steam bottle yet rather than steering to a removed DXMT Steam bottle.
        #expect(vm.statusMessage?.contains("fallback graphics") != true)
        #expect(vm.statusMessage?.contains("isn't supported in the Steam bottle") == true)
    }

    @Test("graphicsFallbackMessage is honest + backend/kind-aware across all branches")
    func graphicsFallbackMessageBranches() {
        typealias VM = GameLibraryViewModel
        // GPTK Steam game → no DXMT Steam bottle to steer to; admit the class isn't supported yet
        // (dxmtAvailable is irrelevant for a Steam game).
        let gptkSteam = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, isSteamGame: true, dxmtAvailable: false)
        #expect(gptkSteam.contains("isn't supported in the Steam bottle"))
        // GPTK manual game → switch this game's backend (configured) / set up DXMT first (not).
        let gptkManualReady = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, isSteamGame: false, dxmtAvailable: true)
        #expect(gptkManualReady.contains("Switch this game's graphics backend to DXMT"))
        let gptkManualNotReady = VM.graphicsFallbackMessage(name: "OC2", backend: .gptk, isSteamGame: false, dxmtAvailable: false)
        #expect(gptkManualNotReady.contains("Set up DXMT in Settings → DXMT first"))
        // DXMT backend (manual only) → names DXMT, admits the wined3d fallback likely failed, points at Settings.
        let dxmt = VM.graphicsFallbackMessage(name: "OC2", backend: .dxmt, isSteamGame: false, dxmtAvailable: true)
        #expect(dxmt.contains("DXMT didn't engage") && dxmt.contains("Settings → DXMT"))
        // None of them pretends graphics are "running on fallback graphics".
        for m in [gptkSteam, gptkManualReady, gptkManualNotReady, dxmt] {
            #expect(m.hasPrefix("OC2: "))
            #expect(!m.contains("running on fallback graphics"))
        }
    }

    @Test("terminateAllSync SIGTERMs every launched game, leaving the co-resident Steam client alive")
    func terminateAllOnQuit() async throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (vm, fake, paths) = make(tmp)
        try installSteam(paths)
        let hl2 = try installedGame(paths, appID: 220, name: "HL2", dir: "HL2")
        let tf2 = try installedGame(paths, appID: 440, name: "TF2", dir: "TF2")
        await vm.play(hl2)
        await vm.play(tf2)
        let gamePIDs = Set([hl2, tf2].compactMap { vm.pid(for: $0) })
        try #require(gamePIDs.count == 2)                            // both games launched

        vm.terminateAllSync()

        // Exactly the two game PIDs were SIGTERM'd — Steam's PID (spawned by ensureRunning) is not in the set.
        #expect(Set(fake.terminatedPIDs) == gamePIDs)
    }
}
