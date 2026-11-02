import Foundation
import Testing
@testable import SiloKit

@Suite("ProcessRouting (per-exe D3D10 helper routing, issue #9)")
struct ProcessRoutingTests {
    private let rockstar = ProcessRouting.d3d10Helpers.first { $0.executable == "Launcher.exe" }!

    @Test("The Rockstar Games Launcher is routed, keyed by the basename wine's AppDefaults uses")
    func rockstarLauncherIsKnown() {
        #expect(rockstar.installPaths.contains("Program Files/Rockstar Games/Launcher/Launcher.exe"))
    }

    @Test("A routed helper gets DXVK's d3d10core/d3d11/dxgi native, wine's d3d10_1, and NO D3DMetal modules")
    func helperOverrides() {
        let overrides = Dictionary(uniqueKeysWithValues: ProcessRouting.helperOverrides.map { ($0.module, $0.mode) })
        #expect(overrides["d3d10core"] == "native")
        #expect(overrides["d3d11"] == "native")
        #expect(overrides["dxgi"] == "native")
        #expect(overrides["d3d10_1"] == "builtin")
        // D3DMetal's d3d12 against a non-D3DMetal dxgi crashed the launcher in the reporter's test — disabled.
        for module in ["d3d12", "d3d12core", "nvapi64", "nvngx"] { #expect(overrides[module] == "") }
        // Natively loaded modules must be exactly what DXVK seeds into the prefix.
        let native = Set(ProcessRouting.helperOverrides.filter { $0.mode == "native" }.map { $0.module + ".dll" })
        #expect(native.allSatisfy(GraphicsLinker.isDXVKModule))
    }

    @Test("Every routed module is one GPTK's set already forces — routing only re-scopes GPTK's own claims")
    func routedModulesAreGPTKModules() {
        let gptk = DllOverrideList(parsing: GraphicsBackend.gptk.dllOverrides).keys
        #expect(ProcessRouting.routedModules.isSubset(of: gptk))
    }

    @Test("Silo's global DllOverrides name no backend module — a global plain entry would beat `*module` in env")
    func globalDefaultsLeaveBackendModulesAlone() {
        let global = Set(Silo.defaultDllOverrides.map { DllOverrideList.key(for: $0.name) })
        for backend in GraphicsBackend.allCases {
            #expect(global.isDisjoint(with: DllOverrideList(parsing: backend.dllOverrides).keys))
        }
    }

    @Test("registryScript writes one AppDefaults DllOverrides key per helper (REGEDIT4, CRLF)")
    func registryScript() {
        let reg = ProcessRouting.registryScript(for: [rockstar])
        #expect(reg.hasPrefix("REGEDIT4\r\n"))
        #expect(reg.contains("[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Launcher.exe\\DllOverrides]\r\n"))
        #expect(reg.contains("\"dxgi\"=\"native\"\r\n"))
        #expect(reg.contains("\"d3d12\"=\"\"\r\n"))
    }

    /// `user.reg` exactly as wine serializes it.
    private func userReg(_ values: [String], exe: String = "Launcher.exe") -> String {
        """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Wine\\\\AppDefaults\\\\\(exe)\\\\DllOverrides] 1730000000
        #time=1db2c3d4e5f6a7b
        \(values.joined(separator: "\n"))

        [Software\\\\Wine\\\\DllOverrides] 1730000000
        "d3dxof"="native,builtin"

        """
    }

    private var allValues: [String] {
        ProcessRouting.helperOverrides.map { "\"\($0.module)\"=\"\($0.mode)\"" }
    }

    @Test("isApplied: true only when every routing value is present under the helper's key")
    func isApplied() {
        #expect(ProcessRouting.isApplied(for: [rockstar], userReg: userReg(allValues)))
        #expect(ProcessRouting.isApplied(for: [rockstar], userReg: userReg(allValues, exe: "launcher.EXE")))
        #expect(!ProcessRouting.isApplied(for: [rockstar], userReg: userReg(Array(allValues.dropLast()))))
        #expect(!ProcessRouting.isApplied(for: [rockstar], userReg: userReg(allValues, exe: "Other.exe")))
        #expect(!ProcessRouting.isApplied(for: [rockstar], userReg: ""))
        // A value under a DIFFERENT key (the global DllOverrides) doesn't count.
        let misplaced = userReg([]) + "\n" + allValues.joined(separator: "\n")
        #expect(!ProcessRouting.isApplied(for: [rockstar], userReg: misplaced))
    }

    @Test("installedHelpers finds the launcher under either Program Files dir, and nothing in a bare prefix")
    func installedHelpers() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let prefix = try tmp.makeDir("bottle")
        #expect(ProcessRouting.installedHelpers(in: prefix).isEmpty)
        try tmp.write("bottle/drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe", "MZ")
        #expect(ProcessRouting.installedHelpers(in: prefix) == [rockstar])

        let other = try tmp.makeDir("bottle32")
        try tmp.write("bottle32/drive_c/Program Files (x86)/Rockstar Games/Launcher/Launcher.exe", "MZ")
        #expect(ProcessRouting.installedHelpers(in: other) == [rockstar])
    }
}

@Suite("LaunchOrchestrator — D3D10 helper routing at launch")
struct ProcessRoutingLaunchTests {
    /// A GPTK manual-game launch setup in a temp dir: fake wine runtime, GPTK + DXVK runtimes, a prefix, and
    /// a game exe. `launcher` installs the Rockstar Games Launcher into the prefix.
    private struct Fixture {
        let tmp: TempDir
        let wine: URL
        let prefix: URL
        let backend: BackendConfig
        let game: ManualGame
        var log: URL { tmp.url.appendingPathComponent("m.log") }

        init(launcher: Bool, dxvk: Bool = true) throws {
            tmp = try TempDir()
            try tmp.makeDir("wine/lib/wine/x86_64-windows")
            try tmp.makeDir("wine/lib/wine/x86_64-unix")
            wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
            let gptk = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
            try tmp.makeDir("gptk/lib/wine/x86_64-unix")
            try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "PE:d3d11")
            try FileManager.default.createSymbolicLink(
                atPath: tmp.url.appendingPathComponent("gptk/lib/wine/x86_64-unix/d3d11.so").path,
                withDestinationPath: "../../external/libd3dshared.dylib")
            try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
            var backend = BackendConfig()
            backend.wineBinaryPath = wine
            backend.gptkLibDirPath = gptk
            if dxvk {
                for module in ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"] {
                    try tmp.write("dxvk/lib/wine/x86_64-windows/\(module)", "DXVK:\(module)")
                }
                backend.dxvkLibDirPath = tmp.url.appendingPathComponent("dxvk/lib/wine/x86_64-windows")
            }
            self.backend = backend
            prefix = try tmp.makeDir("bottle")
            if launcher {
                try tmp.write("bottle/drive_c/Program Files/Rockstar Games/Launcher/Launcher.exe", "MZ")
            }
            game = ManualGame(name: "GTA", executablePath: try tmp.write("Games/GTA/PlayGTAV.exe", "MZ"))
        }
    }

    private func regeditCalls(_ fake: FakeProcessRunner) -> [FakeProcessRunner.Invocation] {
        fake.invocations.filter { !$0.detached && $0.arguments.first == "regedit" }
    }

    @Test("GPTK + installed launcher + DXVK: seeds DXVK, writes AppDefaults via regedit, spawns with `*module` env")
    func routesWhenLauncherInstalled() async throws {
        let f = try Fixture(launcher: true); defer { f.tmp.cleanup() }
        let fake = FakeProcessRunner()
        // Snapshot the .reg file while regedit "runs" (it's removed right after).
        let regPath = f.prefix.appendingPathComponent("drive_c/silo-process-routing.reg").path
        let snapshot = f.tmp.url.appendingPathComponent("reg-snapshot").path
        fake.onRun = { inv in
            if inv.arguments.first == "regedit" { try? FileManager.default.copyItem(atPath: regPath, toPath: snapshot) }
        }
        let orchestrator = LaunchOrchestrator(runner: fake, linker: GraphicsLinker())
        _ = try await orchestrator.launchManualGame(
            f.game, backend: f.backend, graphics: .gptk, prefix: f.prefix, logURL: f.log)

        let regedit = try #require(regeditCalls(fake).first)
        #expect(regedit.arguments == ["regedit", "/S", "C:\\silo-process-routing.reg"])
        #expect(regedit.environment["WINEPREFIX"] == f.prefix.path)
        #expect((try? String(contentsOfFile: snapshot, encoding: .utf8))
                == ProcessRouting.registryScript(for: ProcessRouting.d3d10Helpers))
        // The temp .reg file is cleaned up afterwards.
        #expect(!FileManager.default.fileExists(
            atPath: f.prefix.appendingPathComponent("drive_c/silo-process-routing.reg").path))
        // DXVK's natives are seeded — the routed launcher loads them.
        #expect(FileManager.default.fileExists(
            atPath: f.prefix.appendingPathComponent("drive_c/windows/system32/dxgi.dll").path))

        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.environment["WINEDLLOVERRIDES"]?.contains("*dxgi") == true)
        #expect(spawn.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(f.tmp.url.appendingPathComponent("dxvk/lib").path) == true)
    }

    @Test("Already applied in user.reg → no regedit, but the launch is still routed")
    func skipsRegeditWhenApplied() async throws {
        let f = try Fixture(launcher: true); defer { f.tmp.cleanup() }
        let values = ProcessRouting.helperOverrides.map { "\"\($0.module)\"=\"\($0.mode)\"" }.joined(separator: "\n")
        try f.tmp.write("bottle/user.reg",
                        "[Software\\\\Wine\\\\AppDefaults\\\\Launcher.exe\\\\DllOverrides] 1\n\(values)\n")
        let fake = FakeProcessRunner()
        _ = try await LaunchOrchestrator(runner: fake, linker: GraphicsLinker()).launchManualGame(
            f.game, backend: f.backend, graphics: .gptk, prefix: f.prefix, logURL: f.log)
        #expect(regeditCalls(fake).isEmpty)
        #expect(fake.invocations.last { $0.detached }?.environment["WINEDLLOVERRIDES"]?.contains("*dxgi") == true)
    }

    @Test("A failed registry write fails soft: the launch proceeds UNROUTED (plain env, no DXVK on DYLD)")
    func failedRegeditLaunchesUnrouted() async throws {
        let f = try Fixture(launcher: true); defer { f.tmp.cleanup() }
        let fake = FakeProcessRunner()
        fake.queueResult(ProcessResult(exitCode: 1))
        _ = try await LaunchOrchestrator(runner: fake, linker: GraphicsLinker()).launchManualGame(
            f.game, backend: f.backend, graphics: .gptk, prefix: f.prefix, logURL: f.log)
        let spawn = try #require(fake.invocations.last { $0.detached })
        #expect(spawn.environment["WINEDLLOVERRIDES"] == GraphicsBackend.gptk.dllOverrides)
        #expect(spawn.environment["DYLD_FALLBACK_LIBRARY_PATH"]?.contains("/dxvk/lib") == false)
    }

    @Test("No routing without an installed helper, without DXVK, or on a backend that does D3D10",
          arguments: [(false, true, GraphicsBackend.gptk), (true, false, .gptk), (true, true, .dxvk)])
    func noRouting(launcher: Bool, dxvk: Bool, graphics: GraphicsBackend) async throws {
        let f = try Fixture(launcher: launcher, dxvk: dxvk); defer { f.tmp.cleanup() }
        let fake = FakeProcessRunner()
        _ = try await LaunchOrchestrator(runner: fake, linker: GraphicsLinker()).launchManualGame(
            f.game, backend: f.backend, graphics: graphics, prefix: f.prefix, logURL: f.log)
        #expect(regeditCalls(fake).isEmpty)
        #expect(fake.invocations.last { $0.detached }?.environment["WINEDLLOVERRIDES"] == graphics.dllOverrides)
    }
}

@Suite("BackendChooser — D3D10-only titles never go to GPTK")
struct D3D10RoutingChooserTests {
    @Test("GPTK has no D3D10; DXMT and DXVK do")
    func supportsD3D10() {
        #expect(!GraphicsBackend.gptk.supportsD3D10)
        #expect(GraphicsBackend.dxmt.supportsD3D10)
        #expect(GraphicsBackend.dxvk.supportsD3D10)
    }

    @Test("A 64-bit D3D10-only game goes to DXMT; a learned DXVK hint is honored, a GPTK one is not")
    func d3d10OnlyRouting() {
        let d3d10 = D3DProfile(usesD3D10: true)
        #expect(d3d10.isD3D10Only && d3d10.usesD3D1x)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: d3d10) == .dxmt)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: d3d10, learned: .dxvk) == .dxvk)
        #expect(BackendChooser.choose(.auto, is32Bit: false, profile: d3d10, learned: .gptk) == .dxmt)
        #expect(BackendChooser.choose(.gptk, is32Bit: false, profile: d3d10) == .gptk)   // a pin still wins
    }

    @Test("D3D10 alongside D3D11 or D3D12, or a tier-less D3D10/11 profile, keeps the GPTK-first path")
    func notD3D10Only() {
        for profile in [D3DProfile(usesD3D10: true, usesD3D11: true), D3DProfile(usesD3D10: true, usesD3D12: true),
                        D3DProfile(usesD3D1x: true)] {
            #expect(!profile.isD3D10Only)
            #expect(BackendChooser.choose(.auto, is32Bit: false, profile: profile) == .gptk)
        }
    }

    @Test("scan sets the D3D10 / D3D11 tiers from the real import table")
    func scanTiers() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let d3d10Exe = tmp.url.appendingPathComponent("a/game.exe")
        try FileManager.default.createDirectory(at: d3d10Exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PEFixture.withImports(magic: 0x20b, machine: 0x8664, imports: ["d3d10_1.dll"]).write(to: d3d10Exe)
        let p10 = D3DProfile.scan(executable: d3d10Exe)
        #expect(p10.usesD3D10 && !p10.usesD3D11 && p10.isD3D10Only)

        let d3d11Exe = tmp.url.appendingPathComponent("b/game.exe")
        try FileManager.default.createDirectory(at: d3d11Exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PEFixture.withImports(magic: 0x20b, machine: 0x8664, imports: ["d3d11.dll", "d3d10.dll"]).write(to: d3d11Exe)
        let p11 = D3DProfile.scan(executable: d3d11Exe)
        #expect(p11.usesD3D11 && p11.usesD3D10 && !p11.isD3D10Only)
    }
}
