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
