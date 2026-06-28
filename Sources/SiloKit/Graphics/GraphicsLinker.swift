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
    /// `lib/external` (`libd3dshared.dylib` + `D3DMetal.framework`) is copied into `<wine>/lib/external`
    /// so those symlinks — and the launch DYLD fallback paths — resolve. The runtime is then
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

        let wineLib = wineBinary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib")                                                 // <wine>/lib
        let wineWinDir = wineLib.appendingPathComponent("wine/x86_64-windows")
        let wineUnixDir = wineLib.appendingPathComponent("wine/x86_64-unix")
        let wineExternal = wineLib.appendingPathComponent("external")

        let modules = try fileManager.contentsOfDirectory(at: gptkLibDir, includingPropertiesForKeys: nil)
            .filter { Self.isGPTKModule($0.lastPathComponent) }
        guard !modules.isEmpty else { return }

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
        // libd3dshared.dylib + D3DMetal.framework (the Metal backend the `.so` symlinks + DYLD resolve).
        for item in (try? fileManager.contentsOfDirectory(at: gptkExternal, includingPropertiesForKeys: nil)) ?? [] {
            try replace(item, in: wineExternal)
        }
    }

    // MARK: - Helpers

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
