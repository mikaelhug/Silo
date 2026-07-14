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

    @Test("Steam resolves the Steam bottle on the base runtime, GPTK overlaid in place")
    func steamGPTK() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let ctx = try BottleResolver(paths: paths).steam(backend: .gptk, config: config)

        #expect(ctx.graphics == .gptk)
        #expect(ctx.prefix.lastPathComponent == "SteamBottle")
        #expect(ctx.wineBinary == config.wineBinaryPath)   // GPTK overlays the base runtime in place
        // GPTK overlaid into the base runtime.
        let overlaid = tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d11.dll")
        #expect(try String(contentsOf: overlaid, encoding: .utf8) == "GPTK-PE")
    }

    @Test("Steam with a DXMT backend resolves the SAME Steam prefix on the DXMT variant runtime")
    func steamDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let ctx = try BottleResolver(paths: paths).steam(backend: .dxmt, config: config)

        #expect(ctx.graphics == .dxmt)
        #expect(ctx.prefix == paths.steamBottle)                    // the shared Steam prefix, NOT a manual bottle
        #expect(ctx.wineBinary.path.contains("/wine-dxmt/bin/wine64"))   // the DXMT variant clone
    }

    @Test("Steam with an unconfigured DXMT backend refuses — never mis-routes onto the base runtime")
    func steamDXMTNotConfigured() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp, dxmt: false)   // wine + GPTK only
        #expect(throws: BottleResolver.ResolveError.backendNotConfigured(.dxmt)) {
            try BottleResolver(paths: paths).steam(backend: .dxmt, config: config)
        }
    }

    // MARK: - Manual routing (the DXMT graphics backend now runs only for manual games)

    @Test("Manual game resolves its OWN isolated bottle under its chosen backend's runtime")
    func manualDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let game = ManualGame(name: "Old", executablePath: URL(fileURLWithPath: "/g/old.exe"), graphics: .dxmt)
        let ctx = try BottleResolver(paths: paths).manual(game, backend: .dxmt, config: config)

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
            try BottleResolver(paths: paths).steam(backend: .gptk, config: BackendConfig())
        }
    }

    @Test("Refuses a DXMT manual game when its runtime isn't installed — never mis-routes onto the base runtime")
    func dxmtNotConfigured() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp, dxmt: false)   // wine + GPTK only
        let game = ManualGame(name: "Old", executablePath: URL(fileURLWithPath: "/g/old.exe"), graphics: .dxmt)
        #expect(throws: BottleResolver.ResolveError.backendNotConfigured(.dxmt)) {
            try BottleResolver(paths: paths).manual(game, backend: .dxmt, config: config)
        }
    }

    @Test("GPTK without its lib dir degrades to wine's own wined3d on the base runtime (the baseline)")
    func gptkFallsBackToWined3d() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp, gptk: false)   // wine only, no GPTK overlay
        let ctx = try BottleResolver(paths: paths).steam(backend: .gptk, config: config)
        #expect(ctx.graphics == .gptk)
        #expect(ctx.wineBinary == config.wineBinaryPath)   // base runtime, un-overlaid
    }

    // MARK: - Tool routing (winecfg / regedit / retina — prefix-wide, backend-agnostic, base runtime)

    @Test("steamTool/manualTool resolve the right prefix on the base runtime (no backend variant)")
    func toolTargets() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (config, paths) = try fixtures(tmp)
        let resolver = BottleResolver(paths: paths)

        let steam = try resolver.steamTool(config: config)
        #expect(steam.prefix == paths.steamBottle)
        #expect(steam.wineBinary == config.wineBinaryPath)   // base runtime, never a GPTK/DXMT variant

        let id = UUID()
        let manual = try resolver.manualTool(id, config: config)
        #expect(manual.prefix == paths.manualBottle(id))
        #expect(manual.wineBinary == config.wineBinaryPath)
    }

    @Test("a tool target throws wineNotConfigured when no wine is set")
    func toolTargetNeedsWine() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let (_, paths) = try fixtures(tmp)
        #expect(throws: BottleResolver.ResolveError.wineNotConfigured) {
            try BottleResolver(paths: paths).steamTool(config: BackendConfig())   // no wineBinaryPath
        }
    }
}
