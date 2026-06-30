import Foundation

/// Wires GPTK / D3DMetal into the wine runtime so wine loads D3DMetal-backed Direct3D directly.
///
/// **GPTK / D3DMetal** (`overlayGPTK`) — Apple's D3DMetal d3d modules are *overlaid into the wine
/// runtime's own `lib/wine` tree*. Wine pairs a PE d3d dll with the unix `.so` it finds in its OWN
/// `lib/wine/x86_64-unix`, so GPTK's D3DMetal-backed `.so` must physically replace wine's `wined3d`
/// one there. Merely putting GPTK's PE dll on `WINEDLLPATH` (or symlinking it into `system32`) loads
/// the dll but keeps wine's OpenGL backend, and `D3D11CreateDevice` fails (`0x80004005`). Verified
/// on-device: the overlay is what makes a native DX11 game create a real D3DMetal device.
public struct GraphicsLinker: Sendable {
    public init() {}
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public enum LinkError: Error, Sendable, Equatable {
        case sourceMissing(URL)
    }

    // MARK: - GPTK / D3DMetal overlay

    /// The modules GPTK ships in its `lib/wine` tree — and only these: the Direct3D/DXGI translation
    /// (`d3d*`, `dxgi*`) plus the NVIDIA shims that back MetalFX upscaling (`nv*` — `nvapi64`,
    /// `nvngx-on-metalfx`). Used to select what to overlay, and as a guard so we never clobber an
    /// unrelated wine module should a future GPTK ship more than its d3d tree.
    static func isGPTKModule(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".dll") || n.hasSuffix(".so") else { return false }
        return n.hasPrefix("d3d") || n.hasPrefix("dxgi") || n.hasPrefix("nv")
    }

    /// Overlay Apple GPTK's D3DMetal modules into the **wine runtime** (not a game prefix) so wine loads
    /// D3DMetal-backed Direct3D directly. For each GPTK graphics module the PE `.dll` is copied into
    /// `<wine>/lib/wine/x86_64-windows` and its unix `.so` (a *relative* symlink to
    /// `../../external/libd3dshared.dylib`) is recreated in `<wine>/lib/wine/x86_64-unix`; GPTK's
    /// `lib/external` (`libd3dshared.dylib` + `D3DMetal.framework`) is copied into `<wine>/lib/external`.
    /// Critically, `D3DMetal.framework` is ALSO symlinked into `x86_64-unix` (see `linkD3DMetalFramework`):
    /// wine loads the d3d `.so` from there, so dyld resolves libd3dshared's `@loader_path`-relative `@rpath`
    /// against that dir — and that's where libd3dshared dlopens `D3DMetal.framework`. The runtime is then
    /// self-contained for D3DMetal: GPTK isn't consulted at launch.
    ///
    /// Idempotent: a no-op once the runtime already carries this GPTK's modules, so it's safe to call
    /// before every launch — it re-applies only after a runtime re-download or a GPTK update.
    ///
    /// - Parameters:
    ///   - wineBinary: the runtime's wine binary (`<wine>/bin/wine64`), used to locate `<wine>/lib`.
    ///   - gptkLibDir: GPTK's PE module dir (`<gptk>/lib/wine/x86_64-windows`).
    public func overlayGPTK(wineBinary: URL, gptkLibDir: URL) throws {
        guard fileManager.fileExists(atPath: gptkLibDir.path) else { throw LinkError.sourceMissing(gptkLibDir) }
        let gptkLib = gptkLibDir.deletingLastPathComponent().deletingLastPathComponent()   // <gptk>/lib
        let gptkUnixDir = gptkLib.appendingPathComponent("wine/x86_64-unix")
        let gptkExternal = gptkLib.appendingPathComponent("external")

        let wineLayout = WineRuntimeLayout(wineBinary: wineBinary)
        let wineWinDir = wineLayout.windowsModulesDir
        let wineUnixDir = wineLayout.unixModulesDir
        let wineExternal = wineLayout.externalDir

        let modules = try fileManager.contentsOfDirectory(at: gptkLibDir, includingPropertiesForKeys: nil)
            .filter { Self.isGPTKModule($0.lastPathComponent) }
        guard !modules.isEmpty else { return }

        // Ensure D3DMetal.framework is reachable from the unix-modules dir. Runs on EVERY call (idempotent)
        // so a runtime overlaid before this fix self-repairs — it MUST precede the witness early-return
        // below, which would otherwise skip a runtime whose modules are in place but whose framework link
        // is missing (the silent-wined3d-fallback regression).
        try linkD3DMetalFramework(unixDir: wineUnixDir, externalDir: wineExternal)

        // Idempotent: if a witness module is already byte-identical, the runtime carries THIS GPTK — skip.
        let witness = modules.first { $0.lastPathComponent == "d3d11.dll" } ?? modules[0]
        if fileManager.contentsEqual(
            atPath: witness.path,
            andPath: wineWinDir.appendingPathComponent(witness.lastPathComponent).path) { return }

        try fileManager.createDirectory(at: wineExternal, withIntermediateDirectories: true)
        for dll in modules {
            try replace(dll, in: wineWinDir)
            // The matching unix `.so` is GPTK's D3DMetal bridge (a relative symlink we must preserve).
            let so = gptkUnixDir.appendingPathComponent(
                (dll.lastPathComponent as NSString).deletingPathExtension + ".so")
            if isSymlink(so) || fileManager.fileExists(atPath: so.path) { try replace(so, in: wineUnixDir) }
        }
        // libd3dshared.dylib + D3DMetal.framework (the Metal backend the `.so` symlinks resolve against).
        for item in (try? fileManager.contentsOfDirectory(at: gptkExternal, includingPropertiesForKeys: nil)) ?? [] {
            try replace(item, in: wineExternal)
        }
        // Now that D3DMetal.framework is in lib/external, link it into the unix-modules dir (the pre-witness
        // call above was a no-op on a fresh runtime where the framework didn't exist yet).
        try linkD3DMetalFramework(unixDir: wineUnixDir, externalDir: wineExternal)
    }

    // MARK: - DXMT overlay

    /// The modules DXMT ships in its `lib/wine` tree: its Direct3D 10/11 translation (`d3d11`, `d3d10core`,
    /// `dxgi`) plus the `winemetal` Metal bridge (PE `winemetal.dll` + unix `winemetal.so`). DXMT is
    /// D3D10/11 only — it ships no `d3d12` and no `d3d9`. Used to select what to overlay and as a guard so
    /// we never clobber an unrelated wine module.
    static func isDXMTModule(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".dll") || n.hasSuffix(".so") else { return false }
        return n.hasPrefix("d3d") || n.hasPrefix("dxgi") || n.hasPrefix("winemetal")
    }

    /// Overlay 3Shain's DXMT modules into the **wine runtime** (not a game prefix) so wine loads DXMT's
    /// Metal-backed Direct3D directly, exactly as `overlayGPTK` does for D3DMetal. For each DXMT PE module
    /// the `.dll` is copied into `<wine>/lib/wine/x86_64-windows`; the only matching unix `.so` is DXMT's
    /// `winemetal.so` (its Metal bridge), recreated in `<wine>/lib/wine/x86_64-unix` (the `d3d*`/`dxgi`
    /// PEs are pure forwarders to `winemetal` and have no `.so`). Unlike GPTK, DXMT ships nothing in
    /// `lib/external` — `winemetal.so` links the system `Metal.framework` — so there is no framework
    /// symlink to maintain. The translated modules are forced to builtin at launch
    /// (`GraphicsBackend.dxmt.dllOverrides`, incl. `winemetal=b`) so wine loads these overlaid versions.
    ///
    /// Idempotent: a no-op once the runtime already carries this DXMT's modules, so it's safe to call
    /// before every launch — it re-applies only after a runtime re-download or a DXMT update.
    ///
    /// - Parameters:
    ///   - wineBinary: the runtime's wine binary (`<wine>/bin/wine64`), used to locate `<wine>/lib`.
    ///   - dxmtLibDir: DXMT's PE module dir (`<dxmt>/lib/wine/x86_64-windows`).
    public func overlayDXMT(wineBinary: URL, dxmtLibDir: URL) throws {
        guard fileManager.fileExists(atPath: dxmtLibDir.path) else { throw LinkError.sourceMissing(dxmtLibDir) }
        let dxmtUnixDir = dxmtLibDir.deletingLastPathComponent().appendingPathComponent("x86_64-unix")

        let wineLayout = WineRuntimeLayout(wineBinary: wineBinary)
        let wineWinDir = wineLayout.windowsModulesDir
        let wineUnixDir = wineLayout.unixModulesDir

        let modules = try fileManager.contentsOfDirectory(at: dxmtLibDir, includingPropertiesForKeys: nil)
            .filter { Self.isDXMTModule($0.lastPathComponent) }
        guard !modules.isEmpty else { return }

        // Idempotent: if a witness module is already byte-identical, the runtime carries THIS DXMT — skip.
        let witness = modules.first { $0.lastPathComponent == "d3d11.dll" } ?? modules[0]
        if fileManager.contentsEqual(
            atPath: witness.path,
            andPath: wineWinDir.appendingPathComponent(witness.lastPathComponent).path) { return }

        try fileManager.createDirectory(at: wineWinDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wineUnixDir, withIntermediateDirectories: true)
        for dll in modules {
            try replace(dll, in: wineWinDir)
            // The matching unix `.so` (only `winemetal.so` actually exists) is DXMT's Metal bridge.
            let so = dxmtUnixDir.appendingPathComponent(
                (dll.lastPathComponent as NSString).deletingPathExtension + ".so")
            if isSymlink(so) || fileManager.fileExists(atPath: so.path) { try replace(so, in: wineUnixDir) }
        }
    }

    // MARK: - Helpers

    /// The relative symlink target from `<wine>/lib/wine/x86_64-unix` to the overlaid framework.
    static let d3dMetalUnixLinkTarget = "../../external/D3DMetal.framework"

    /// Make `D3DMetal.framework` reachable from the unix-modules dir. wine loads GPTK's d3d `.so` via a
    /// symlink in `x86_64-unix`, so dyld resolves libd3dshared's `@loader_path` (its only `@rpath`) to THAT
    /// dir; libd3dshared then dlopens `@rpath/D3DMetal.framework/D3DMetal`, which must therefore resolve
    /// from `x86_64-unix`. Without this link the dlopen fails (`"Failed to dlopen D3DMetal"`) and wine
    /// silently falls back to wined3d — GPTK never engages. Idempotent; a no-op until the framework exists
    /// in `lib/external` (so the first, pre-copy call on a fresh runtime does nothing) and once correctly
    /// linked.
    private func linkD3DMetalFramework(unixDir: URL, externalDir: URL) throws {
        guard fileManager.fileExists(atPath: externalDir.appendingPathComponent("D3DMetal.framework").path)
        else { return }
        let link = unixDir.appendingPathComponent("D3DMetal.framework")
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == Self.d3dMetalUnixLinkTarget {
            return   // already correctly linked
        }
        if isSymlink(link) || fileManager.fileExists(atPath: link.path) { try fileManager.removeItem(at: link) }
        try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: Self.d3dMetalUnixLinkTarget)
    }

    /// Place `src` into `dir` under its own name, replacing any existing entry. A symlink is **recreated**
    /// with the same (relative) target — not dereferenced — so GPTK's `.so` links keep resolving against
    /// the wine tree rather than collapsing into a standalone dylib whose `@rpath` framework lookup breaks.
    /// Regular files and directories (e.g. `D3DMetal.framework`) are copied recursively.
    private func replace(_ src: URL, in dir: URL) throws {
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        if fileManager.fileExists(atPath: dest.path) || isSymlink(dest) { try fileManager.removeItem(at: dest) }
        if isSymlink(src) {
            let target = try fileManager.destinationOfSymbolicLink(atPath: src.path)
            try fileManager.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
        } else {
            try fileManager.copyItem(at: src, to: dest)
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
