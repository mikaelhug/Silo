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

    // MARK: - DXMT overlay

    /// Build a minimal DXMT runtime tree and return its `lib/wine/x86_64-windows` dir (the `dxmtLibDir`).
    /// DXMT's real layout: PE `d3d11`/`d3d10core`/`dxgi`/`winemetal` dlls, and ONE unix `.so` —
    /// `winemetal.so` (a real dylib, not a symlink) — the d3d PEs forward to winemetal and have no `.so`.
    @discardableResult
    private func makeDXMT(_ tmp: TempDir) throws -> URL {
        let win = try tmp.makeDir("dxmt/lib/wine/x86_64-windows")
        try tmp.makeDir("dxmt/lib/wine/x86_64-unix")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/x86_64-windows/\(module)", "PE:\(module)")
        }
        try tmp.write("dxmt/lib/wine/x86_64-unix/winemetal.so", "WINEMETAL-DYLIB")
        return win
    }

    @Test("overlayDXMT copies DXMT's d3d/winemetal PE modules + winemetal.so into the wine runtime")
    func overlayDXMTCopiesModules() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            let dest = wineLib.appendingPathComponent("wine/x86_64-windows/\(dll)")
            #expect(FileManager.default.contentsEqual(
                atPath: dest.path, andPath: dxmtLibDir.appendingPathComponent(dll).path))
        }
        // The Metal bridge .so is overlaid as a real file (DXMT's winemetal.so isn't a symlink).
        let so = wineLib.appendingPathComponent("wine/x86_64-unix/winemetal.so")
        #expect(try String(contentsOf: so, encoding: .utf8) == "WINEMETAL-DYLIB")
    }

    @Test("overlayDXMT overlays ONLY winemetal.so (the d3d PEs are pure forwarders) and touches no lib/external")
    func overlayDXMTNoStrayUnixOrExternal() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        // No d3d11.so / dxgi.so etc. (DXMT's d3d modules have no unix half), and no lib/external at all.
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/d3d11.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/dxgi.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("external").path))
    }

    @Test("overlayDXMT is idempotent and re-applies on a DXMT update")
    func overlayDXMTIdempotentAndReapplies() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        let wine = try makeWine(tmp)
        let d3d11 = wine.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)
        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)   // no throw, still correct
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll")

        try tmp.write("dxmt/lib/wine/x86_64-windows/d3d11.dll", "PE:d3d11.dll v2")  // DXMT update
        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)
        #expect(try String(contentsOf: d3d11, encoding: .utf8) == "PE:d3d11.dll v2")
    }

    @Test("overlayDXMT throws sourceMissing when DXMT's module dir does not exist")
    func overlayDXMTSourceMissing() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let wine = try makeWine(tmp)
        let missing = tmp.url.appendingPathComponent("nope/lib/wine/x86_64-windows")
        #expect(throws: GraphicsLinker.LinkError.sourceMissing(missing)) {
            try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: missing)
        }
    }

    @Test("overlayDXMT ALSO overlays the i386 tree when the release ships 32-bit libs (so 32-bit games get DXMT)")
    func overlayDXMTBothArches() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)
        // A both-ABI release: an i386-windows sibling with 32-bit d3d PEs. (No i386-unix — the i386
        // winemetal.dll thunks into the shared x86_64-unix/winemetal.so, so the 32-bit tree ships no .so.)
        try tmp.makeDir("dxmt/lib/wine/i386-windows")
        for module in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            try tmp.write("dxmt/lib/wine/i386-windows/\(module)", "PE32:\(module)")
        }
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        // 64-bit tree overlaid as before…
        #expect(try String(contentsOf:
            wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"), encoding: .utf8) == "PE:d3d11.dll")
        // …AND the 32-bit tree, so a 32-bit game loads DXMT's i386 d3d11 (not stock wined3d).
        for dll in ["d3d11.dll", "d3d10core.dll", "dxgi.dll", "winemetal.dll"] {
            #expect(try String(contentsOf:
                wineLib.appendingPathComponent("wine/i386-windows/\(dll)"), encoding: .utf8) == "PE32:\(dll)")
        }
        // The shared unix bridge stays in x86_64-unix; no i386-unix is fabricated.
        #expect(FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/x86_64-unix/winemetal.so").path))
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/i386-unix").path))
    }

    @Test("overlayDXMT leaves the i386 tree untouched for a 64-bit-only release (backward compatible)")
    func overlayDXMT64BitOnlyRelease() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        let dxmtLibDir = try makeDXMT(tmp)   // x86_64 only, no i386-windows sibling
        let wine = try makeWine(tmp)
        let wineLib = wine.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")

        try linker.overlayDXMT(wineBinary: wine, dxmtLibDir: dxmtLibDir)

        #expect(try String(contentsOf:
            wineLib.appendingPathComponent("wine/x86_64-windows/d3d11.dll"), encoding: .utf8) == "PE:d3d11.dll")
        #expect(!FileManager.default.fileExists(atPath: wineLib.appendingPathComponent("wine/i386-windows").path))
    }

    @Test("isOverlayModule: only .dll/.so with a backend's module prefixes; the two filters diverge right")
    func overlayModulePredicate() {
        #expect(GraphicsLinker.isOverlayModule("d3d11.dll", prefixes: ["d3d"]))
        #expect(GraphicsLinker.isOverlayModule("D3D11.DLL", prefixes: ["d3d"]))       // case-insensitive
        #expect(!GraphicsLinker.isOverlayModule("d3d11.txt", prefixes: ["d3d"]))      // wrong extension
        #expect(!GraphicsLinker.isOverlayModule("kernel32.dll", prefixes: ["d3d", "dxgi"]))   // guard
        // The backend filters parameterize the shared predicate — their DIFFERENCES must survive:
        #expect(GraphicsLinker.isGPTKModule("nvngx.dll") && !GraphicsLinker.isDXMTModule("nvngx.dll"))
        #expect(GraphicsLinker.isDXMTModule("winemetal.so") && !GraphicsLinker.isGPTKModule("winemetal.so"))
    }

    @Test("witnessMatches: skip only when the witness is byte-identical in the runtime")
    func witnessCheck() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        _ = try tmp.makeDir("src"); let win = try tmp.makeDir("win")
        try tmp.write("src/d3d11.dll", "V1")
        try tmp.write("src/dxgi.dll", "V1")
        let modules = [tmp.url.appendingPathComponent("src/d3d11.dll"),
                       tmp.url.appendingPathComponent("src/dxgi.dll")]
        #expect(!linker.witnessMatches(modules, in: win))    // nothing overlaid yet
        try tmp.write("win/d3d11.dll", "V1")
        #expect(linker.witnessMatches(modules, in: win))     // this build already overlaid → skip
        try tmp.write("win/d3d11.dll", "V2")
        #expect(!linker.witnessMatches(modules, in: win))    // an updated build re-applies
        #expect(!linker.witnessMatches([], in: win))         // no modules → never "already overlaid"
    }
}
