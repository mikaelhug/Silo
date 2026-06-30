import Foundation
import Testing
@testable import SiloKit

@Suite("GraphicsLinker")
struct GraphicsLinkerTests {
    let linker = GraphicsLinker()

    // MARK: - Fixtures

    /// Build a minimal GPTK runtime tree and return its `lib/wine/x86_64-windows` dir (the `gptkLibDir`).
    /// Each module gets a PE `.dll` + a relative-symlink `.so` (GPTK's real layout); `lib/external` holds
    /// `libd3dshared.dylib` + a `D3DMetal.framework` directory.
    @discardableResult
    private func makeGPTK(_ tmp: TempDir, modules: [String] = ["d3d11.dll", "d3d10.dll", "nvapi64.dll"]) throws -> URL {
        let win = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        let unix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
        try tmp.makeDir("gptk/lib/external/D3DMetal.framework")
        for module in modules {
            try tmp.write("gptk/lib/wine/x86_64-windows/\(module)", "PE:\(module)")
            let so = unix.appendingPathComponent((module as NSString).deletingPathExtension + ".so")
            try FileManager.default.createSymbolicLink(
                atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
        try tmp.write("gptk/lib/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
        return win
    }

    /// Build a minimal wine runtime tree (empty d3d dirs) and return its wine binary (`bin/wine64`).
    private func makeWine(_ tmp: TempDir) throws -> URL {
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        return try tmp.write("wine/bin/wine64", "#!/bin/sh")
    }

    // MARK: - GPTK overlay

    @Test("overlayGPTK copies GPTK's d3d modules into the wine runtime's lib/wine + lib/external")
    func overlayCopiesModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // PE dll overlaid byte-for-byte.
        let d3d11 = wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        #expect(FileManager.default.contentsEqual(
            atPath: d3d11.path, andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
        // Unix .so recreated AS a relative symlink (not dereferenced into a dylib copy).
        let so = wineLib.appendingPathComponent("wine/x86_64-unix/d3d11.so")
        #expect((try so.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: so.path)
            == "../../external/libd3dshared.dylib")
        // The Metal backend (lib/external) is overlaid so those symlinks + DYLD resolve.
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external/libd3dshared.dylib").path))
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external/D3DMetal.framework/D3DMetal").path))
    }

    @Test("overlayGPTK is idempotent — a second call is a no-op and does not throw")
    func overlayIdempotent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)   // no throw, still correct

        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        #expect(FileManager.default.contentsEqual(
            atPath: d3d11.path, andPath: gptkLibDir.appendingPathComponent("d3d11.dll").path))
    }

    @Test("overlayGPTK re-applies when GPTK's modules change (e.g. a GPTK update)")
    func overlayReappliesOnUpdate() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // A GPTK update rewrites d3d11.dll; the overlay must pick up the new bytes.
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d11.dll", "PE:d3d11.dll v2")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll v2")
    }

    @Test("overlayGPTK only touches d3d/dxgi/nv modules — unrelated wine dlls are left intact")
    func overlayScopedToGPTKModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp, modules: ["d3d11.dll"])
        // A stray non-graphics dll in GPTK's source must NOT clobber the wine runtime's own copy.
        try tmp.write("gptk/lib/wine/x86_64-windows/kernel32.dll", "GPTK-STRAY")
        let wine = try makeWine(tmp)
        try tmp.write("wine/lib/wine/x86_64-windows/kernel32.dll", "WINE-REAL")

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        let kernel32 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/kernel32.dll")
        #expect(try String(contentsOf: kernel32, encoding: .utf8) == "WINE-REAL")   // untouched
    }

    @Test("overlayGPTK selects a fallback witness when d3d11.dll is absent and re-applies on update")
    func overlayFallbackWitness() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        // SINGLE non-d3d11 module → witness is unambiguously modules[0] (no d3d11.dll present).
        let gptkLibDir = try makeGPTK(tmp, modules: ["d3d12.dll"])
        let wine = try makeWine(tmp)
        let wineWin = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")

        // 1. First overlay completes the copy via the fallback witness (not a short-circuit).
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(FileManager.default.contentsEqual(
            atPath: wineWin.path, andPath: gptkLibDir.appendingPathComponent("d3d12.dll").path))

        // 2. A GPTK update rewrites d3d12.dll; the fallback-keyed idempotency check must DETECT it + re-apply.
        try tmp.write("gptk/lib/wine/x86_64-windows/d3d12.dll", "PE:d3d12.dll v2")
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try String(contentsOf: wineWin, encoding: .utf8) == "PE:d3d12.dll v2")

        // 3. No-op when unchanged: the witness short-circuit fires; bytes + mtime are untouched.
        let mtime = try FileManager.default.attributesOfItem(atPath: wineWin.path)[.modificationDate] as? Date
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try String(contentsOf: wineWin, encoding: .utf8) == "PE:d3d12.dll v2")
        let mtime2 = try FileManager.default.attributesOfItem(atPath: wineWin.path)[.modificationDate] as? Date
        #expect(mtime == mtime2)   // not re-copied (guards the re-copy-every-launch failure mode)
    }

    @Test("overlayGPTK links D3DMetal.framework into the unix-modules dir (so libd3dshared's @rpath resolves it)")
    func overlayLinksD3DMetalFramework() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)

        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // wine loads the d3d `.so` from x86_64-unix, so libd3dshared's @loader_path resolves there — the
        // framework must be reachable from that dir or the D3DMetal dlopen fails → silent wined3d fallback.
        let link = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/D3DMetal.framework")
        #expect((try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "../../external/D3DMetal.framework")
    }

    @Test("overlayGPTK self-repairs a runtime missing the D3DMetal.framework unix link (the pre-fix regression)")
    func overlaySelfRepairsMissingFrameworkLink() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let gptkLibDir = try makeGPTK(tmp)
        let wine = try makeWine(tmp)
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)

        // Simulate the broken state: modules already overlaid (witness byte-identical) but the framework
        // link deleted — exactly the runtime that silently fell back to wined3d before this fix.
        let link = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/D3DMetal.framework")
        try FileManager.default.removeItem(at: link)
        #expect(!FileManager.default.fileExists(atPath: link.path))

        // The next overlay must re-create the link even though the witness short-circuits the module copy.
        try linker.overlayGPTK(wineBinary: wine, gptkLibDir: gptkLibDir)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            == "../../external/D3DMetal.framework")
    }

    @Test("overlayGPTK throws sourceMissing when GPTK's module dir does not exist")
    func overlaySourceMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let missing = tmp.url.appendingPathComponent("nope/lib/wine/x86_64-windows")
        #expect(throws: GraphicsLinker.LinkError.sourceMissing(missing)) {
            try linker.overlayGPTK(wineBinary: wine, gptkLibDir: missing)
        }
    }
}
