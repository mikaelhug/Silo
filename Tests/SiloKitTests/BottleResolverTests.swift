import Foundation
import Testing
@testable import SiloKit

@Suite("BottleResolver + RuntimeVariants")
struct BottleResolverTests {

    // MARK: - Fixtures

    /// A base wine runtime (`wine/bin/wine64` + empty module dirs) and minimal GPTK + DXMT source trees.
    /// Returns the configured backend + the AppPaths rooted in `tmp`.
    private func fixtures(_ tmp: TempDir, gptk: Bool = true, dxmt: Bool = true) throws -> (BackendConfig, AppPaths) {
        let wine = try tmp.write("wine/bin/wine64", "#!/bin/sh")
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")

        var config = BackendConfig()
        config.wineBinaryPath = wine
        if gptk {
            let win = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
            let unix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
            try tmp.makeDir("gptk/lib/external/D3DMetal.framework")
            try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "GPTK-PE")
            try FileManager.default.createSymbolicLink(
                atPath: unix.appendingPathComponent("d3d11.so").path,
                withDestinationPath: "../../external/libd3dshared.dylib")
            try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
            try tmp.write("gptk/lib/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
            config.gptkLibDirPath = win
        }
        if dxmt {
            let win = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
            try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
            for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
                try tmp.write("dxmt/lib/wine/x86_64-windows/\(module)", "DXMT:\(module)")
            }
            try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WINEMETAL")
            config.dxmtLibDirPath = win
        }
        return (config, AppPaths(supportDir: tmp.url.appendingPathComponent("Silo")))
    }

    // MARK: - Steam routing

    @Test("Steam GPTK resolves the GPTK bottle on the base runtime, overlaid in place")
    func steamGPTK() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let ctx = try BottleResolver(paths: paths).steam(.gptk, config: config)

        #expect(ctx.graphics == .gptk)
        #expect(ctx.prefix.lastPathComponent == "SteamBottle")
        #expect(ctx.wineBinary == config.wineBinaryPath)   // GPTK overlays the base runtime in place
        // GPTK overlaid into the base runtime.
        let overlaid = tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d11.dll")
        #expect(try String(contentsOf: overlaid, encoding: .utf8) == "GPTK-PE")
    }

    @Test("Steam DXMT resolves the DXMT bottle on a CLONED, DXMT-overlaid runtime (distinct from GPTK's)")
    func steamDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let ctx = try BottleResolver(paths: paths).steam(.dxmt, config: config)

        #expect(ctx.graphics == .dxmt)
        #expect(ctx.prefix.lastPathComponent == "SteamBottle-DXMT")
        // The DXMT runtime is a clone sibling of the base — NOT the base itself.
        #expect(ctx.wineBinary != config.wineBinaryPath)
        #expect(ctx.wineBinary.path.contains("/wine-dxmt/bin/wine64"))
        // DXMT overlaid into the clone (d3d11 + the winemetal bridge .so).
        let cloneWin = tmp.url.appendingPathComponent("wine-dxmt/lib/wine/x86_64-windows/d3d11.dll")
        let cloneSo = tmp.url.appendingPathComponent("wine-dxmt/lib/wine/x86_64-unix/winemetal.so")
        #expect(try String(contentsOf: cloneWin, encoding: .utf8) == "DXMT:d3d11.dll")
        #expect(FileManager.default.fileExists(atPath: cloneSo.path))
    }

    @Test("Determinism: GPTK and DXMT resolve to DISTINCT runtimes — neither can run on the other's tree")
    func distinctRuntimes() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let resolver = BottleResolver(paths: paths)
        let gptk = try resolver.steam(.gptk, config: config)
        let dxmt = try resolver.steam(.dxmt, config: config)
        #expect(gptk.wineBinary != dxmt.wineBinary)
        #expect(gptk.prefix != dxmt.prefix)
    }

    // MARK: - Manual routing

    @Test("Manual game resolves its OWN isolated bottle under its chosen backend's runtime")
    func manualDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let game = ManualGame(name: "Old", executablePath: URL(fileURLWithPath: "/g/old.exe"), backend: .dxmt)
        let ctx = try BottleResolver(paths: paths).manual(game, config: config)

        #expect(ctx.graphics == .dxmt)
        #expect(ctx.prefix == paths.manualBottle(game.id))
        #expect(ctx.wineBinary.path.contains("/wine-dxmt/bin/wine64"))
    }

    // MARK: - Misconfiguration

    @Test("Throws wineNotConfigured when no wine binary is set")
    func noWine() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (_, paths) = try fixtures(tmp)
        #expect(throws: BottleResolver.ResolveError.wineNotConfigured) {
            try BottleResolver(paths: paths).steam(.gptk, config: BackendConfig())
        }
    }

    @Test("Refuses DXMT when its runtime isn't installed — never silently mis-routes onto the base runtime")
    func dxmtNotConfigured() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp, dxmt: false)   // wine + GPTK only
        #expect(throws: BottleResolver.ResolveError.backendNotConfigured(.dxmt)) {
            try BottleResolver(paths: paths).steam(.dxmt, config: config)
        }
    }

    @Test("GPTK without its lib dir degrades to wine's own wined3d on the base runtime (the baseline)")
    func gptkFallsBackToWined3d() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp, gptk: false)   // wine only, no GPTK overlay
        let ctx = try BottleResolver(paths: paths).steam(.gptk, config: config)
        #expect(ctx.graphics == .gptk)
        #expect(ctx.wineBinary == config.wineBinaryPath)   // base runtime, un-overlaid
    }
}
