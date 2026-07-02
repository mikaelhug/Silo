import Foundation
import Testing
@testable import SiloKit

@Suite("RuntimeVariants")
struct RuntimeVariantsTests {

    /// Minimal base wine runtime tree + a marker file so a clone (or its absence) is detectable.
    private func makeWine(_ tmp: TempDir) throws -> URL {
        try tmp.makeDir("wine/lib/wine/x86_64-windows")
        try tmp.makeDir("wine/lib/wine/x86_64-unix")
        try tmp.write("wine/share/marker.txt", "BASE")
        return try tmp.write("wine/bin/wine64", "#!/bin/sh")
    }

    /// A DXMT module dir (the `x86_64-windows` folder `BackendConfig.dxmtLibDirPath` points at).
    private func makeDXMT(_ tmp: TempDir) throws -> URL {
        let lib = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(module)", "DXMT")
        }
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WM")
        return lib
    }

    /// A GPTK module dir (PE dlls + relative-symlink `.so`s + lib/external), as `overlayGPTK` expects.
    private func makeGPTK(_ tmp: TempDir) throws -> URL {
        let win = try tmp.makeDir("gptk/lib/wine/x86_64-windows")
        let unix = try tmp.makeDir("gptk/lib/wine/x86_64-unix")
        try tmp.makeDir("gptk/lib/external/D3DMetal.framework")
        for module in ["d3d11.dll", "dxgi.dll"] {
            try tmp.write("gptk/lib/wine/x86_64-windows/\(module)", "GPTK:\(module)")
            let so = unix.appendingPathComponent((module as NSString).deletingPathExtension + ".so")
            try FileManager.default.createSymbolicLink(
                atPath: so.path, withDestinationPath: "../../external/libd3dshared.dylib")
        }
        try tmp.write("gptk/lib/external/libd3dshared.dylib", "DYLIB")
        try tmp.write("gptk/lib/external/D3DMetal.framework/D3DMetal", "FRAMEWORK")
        return win
    }

    @Test("prepare(.gptk) overlays the BASE runtime in place and returns the base wine (no clone)")
    func prepareGPTK() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let gptkLib = try makeGPTK(tmp)
        let out = try RuntimeVariants().prepare(backend: .gptk, baseWine: wine, libDir: gptkLib)
        #expect(out == wine)                                     // the proven in-place path
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d11.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt").path))   // nothing cloned
    }

    @Test("prepare(.dxmt) clones the base to <root>-dxmt and overlays DXMT into the CLONE only")
    func prepareDXMT() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let dxmtLib = try makeDXMT(tmp)
        let out = try RuntimeVariants().prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        #expect(out.path.hasSuffix("wine-dxmt/bin/wine64"))
        // A full clone (the marker rode along); the overlay landed in the clone, never the base.
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt/share/marker.txt").path))
        #expect(FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine-dxmt/lib/wine/x86_64-windows/winemetal.dll").path))
        #expect(!FileManager.default.fileExists(
            atPath: tmp.url.appendingPathComponent("wine/lib/wine/x86_64-windows/winemetal.dll").path))
    }

    @Test("prepare(.dxmt) keeps an EXISTING clone (idempotent — no wipe on every launch)")
    func prepareDXMTIdempotent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let dxmtLib = try makeDXMT(tmp)
        let variants = RuntimeVariants()
        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        // Mutate a file INSIDE the clone — a re-clone would wipe this.
        let marker = tmp.url.appendingPathComponent("wine-dxmt/share/marker.txt")
        try Data("MUTATED".utf8).write(to: marker)
        _ = try variants.prepare(backend: .dxmt, baseWine: wine, libDir: dxmtLib)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "MUTATED")   // clone NOT re-created
    }

    @Test("variantWine is pure path math — no side effects on disk")
    func variantWinePaths() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = tmp.url.appendingPathComponent("rt/wine/bin/wine64")
        let variants = RuntimeVariants()
        #expect(variants.variantWine(backend: .gptk, baseWine: wine) == wine)
        let dxmt = variants.variantWine(backend: .dxmt, baseWine: wine)
        #expect(dxmt.path.hasSuffix("rt/wine-dxmt/bin/wine64"))
        #expect(!FileManager.default.fileExists(atPath: dxmt.path))   // nothing was created
    }
}
