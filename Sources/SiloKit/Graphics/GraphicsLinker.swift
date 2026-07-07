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
        isOverlayModule(name, prefixes: ["d3d", "dxgi", "nv"])
    }

    /// The shared module filter both backends parameterize: a `.dll`/`.so` whose basename starts with one
    /// of that backend's module prefixes — selects what to overlay AND guards against clobbering an
    /// unrelated wine module.
    static func isOverlayModule(_ name: String, prefixes: [String]) -> Bool {
        let n = name.lowercased()
        guard n.hasSuffix(".dll") || n.hasSuffix(".so") else { return false }
        return prefixes.contains { n.hasPrefix($0) }
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
        if witnessMatches(modules, in: wineWinDir) { return }

        try fileManager.createDirectory(at: wineExternal, withIntermediateDirectories: true)
        // Each PE dll + its matching unix `.so` — GPTK's D3DMetal bridge (relative symlinks preserved).
        try copyModules(modules, unixSource: gptkUnixDir, toWin: wineWinDir, toUnix: wineUnixDir)
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
        isOverlayModule(name, prefixes: ["d3d", "dxgi", "winemetal"])
    }

    /// Overlay 3Shain's DXMT modules into the **wine runtime** (not a game prefix) so wine loads DXMT's
    /// Metal-backed Direct3D directly, exactly as `overlayGPTK` does for D3DMetal. For each DXMT PE module
    /// the `.dll` is copied into `<wine>/lib/wine/<arch>-windows`; the only matching unix `.so` is DXMT's
    /// `winemetal.so` (its Metal bridge), recreated in `<wine>/lib/wine/x86_64-unix` (the `d3d*`/`dxgi`
    /// PEs are pure forwarders to `winemetal` and have no `.so`). Unlike GPTK, DXMT ships nothing in
    /// `lib/external` — `winemetal.so` links the system `Metal.framework` — so there is no framework
    /// symlink to maintain. The translated modules are forced to builtin at launch
    /// (`GraphicsBackend.dxmt.dllOverrides`, incl. `winemetal=b`) so wine loads these overlaid versions.
    ///
    /// **Both ABIs, auto-selected.** DXMT ships its d3d translation for BOTH `x86_64-windows` and
    /// `i386-windows` (when the release includes 32-bit libs). We overlay every `<arch>-windows` sibling the
    /// release carries; wine then loads DXMT's d3d11 from the tree matching the game's PE machine type — a
    /// 64-bit game from `x86_64-windows`, a 32-bit game from `i386-windows` — with no arch detection on
    /// Silo's side. The unix `.so` is host-arch only (new-WoW64): the single `x86_64-unix/winemetal.so`
    /// serves both PE arches, so the i386 tree needs no `.so` of its own. A 64-bit-only release (no i386
    /// sibling) overlays exactly as before.
    ///
    /// Idempotent: a no-op once the runtime already carries this DXMT's modules, so it's safe to call
    /// before every launch — it re-applies only after a runtime re-download or a DXMT update.
    ///
    /// - Parameters:
    ///   - wineBinary: the runtime's wine binary (`<wine>/bin/wine64`), used to locate `<wine>/lib`.
    ///   - dxmtLibDir: DXMT's x86_64 PE module dir (`<dxmt>/lib/wine/x86_64-windows`); its `<arch>-windows`
    ///     / `<arch>-unix` siblings are the source for the other ABIs.
    public func overlayDXMT(wineBinary: URL, dxmtLibDir: URL) throws {
        guard fileManager.fileExists(atPath: dxmtLibDir.path) else { throw LinkError.sourceMissing(dxmtLibDir) }
        let sourceRoot = dxmtLibDir.deletingLastPathComponent()   // holds <arch>-windows + <arch>-unix
        let wineLayout = WineRuntimeLayout(wineBinary: wineBinary)

        for arch in WineArch.allCases {
            let srcWin = sourceRoot.appendingPathComponent("\(arch.rawValue)-windows")
            guard fileManager.fileExists(atPath: srcWin.path),
                  let modules = try? fileManager.contentsOfDirectory(at: srcWin, includingPropertiesForKeys: nil)
                    .filter({ Self.isDXMTModule($0.lastPathComponent) }),
                  !modules.isEmpty
            else { continue }   // this ABI isn't in the release — skip it

            let wineWinDir = wineLayout.windowsModulesDir(arch)
            // Idempotent: if a witness module is already byte-identical, the runtime carries THIS DXMT — skip.
            if witnessMatches(modules, in: wineWinDir) { continue }

            let srcUnix = sourceRoot.appendingPathComponent("\(arch.rawValue)-unix")
            let wineUnixDir = wineLayout.unixModulesDir(arch)
            try fileManager.createDirectory(at: wineWinDir, withIntermediateDirectories: true)
            // Only stand up the unix-modules dir when this ABI actually ships a `.so`. Under new-WoW64 only
            // x86_64 does — the i386 PE winemetal.dll thunks into the shared x86_64-unix/winemetal.so — so
            // the 32-bit pass overlays PEs only and never fabricates an empty `i386-unix`.
            if fileManager.fileExists(atPath: srcUnix.path) {
                try fileManager.createDirectory(at: wineUnixDir, withIntermediateDirectories: true)
            }
            try copyModules(modules, unixSource: srcUnix, toWin: wineWinDir, toUnix: wineUnixDir)
        }
    }

    /// Place DXMT's `winemetal.dll` into the game **prefix** so wine can actually load it. Load-bearing +
    /// non-obvious: `winemetal` is a 3rd-party builtin, so wineboot creates NO fakedll placeholder for it in
    /// the prefix (unlike `d3d11`/`dxgi`, which are standard wine names and DO get one). Wine's import loader
    /// won't consult the `lib/wine` builtin for a DLL it can't first resolve to a file on the Windows search
    /// path — so `dxgi`'s import of `winemetal.dll` fails with `c0000135` (STATUS_DLL_NOT_FOUND) and DXMT
    /// silently falls back to wined3d (→ "no supported feature levels" → the game's graphics-init fails).
    /// Dropping the winemetal PE into `system32` (x86_64) / `syswow64` (i386) makes the search resolve; the
    /// `winemetal=b` override then loads the real builtin + its `winemetal.so` unixlib. Placed for every ABI
    /// the release ships, so wine picks the one matching each game's PE machine type — 32-bit and 64-bit
    /// games both get DXMT with no per-game selection. Idempotent.
    ///
    /// - Parameters:
    ///   - prefix: the game's Wine prefix (`<bottle>` — its `drive_c/windows/{system32,syswow64}` are seeded).
    ///   - dxmtLibDir: DXMT's x86_64 PE module dir; its `<arch>-windows` siblings are the source per ABI.
    public func installDXMTPrefixLoaders(prefix: URL, dxmtLibDir: URL) throws {
        let sourceRoot = dxmtLibDir.deletingLastPathComponent()
        let windows = prefix.appendingPathComponent("drive_c/windows")
        // 64-bit DLLs live in system32, 32-bit in syswow64 (wine's WoW64 layout).
        let dest: [WineArch: URL] = [
            .x86_64: windows.appendingPathComponent("system32"),
            .i386: windows.appendingPathComponent("syswow64"),
        ]
        for arch in WineArch.allCases {
            let src = sourceRoot.appendingPathComponent("\(arch.rawValue)-windows/winemetal.dll")
            guard let destDir = dest[arch], fileManager.fileExists(atPath: src.path) else { continue }
            let dst = destDir.appendingPathComponent("winemetal.dll")
            if fileManager.contentsEqual(atPath: src.path, andPath: dst.path) { continue }   // already placed
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dst.path) { try fileManager.removeItem(at: dst) }
            try fileManager.copyItem(at: src, to: dst)
        }
    }

    // MARK: - Helpers

    /// The idempotency check shared by both overlays: if a representative module (preferring `d3d11.dll`)
    /// is already byte-identical inside the runtime's windows-modules dir, the runtime carries THIS
    /// backend build and the overlay can be skipped. One witness suffices — a backend's modules ship and
    /// update as a set.
    func witnessMatches(_ modules: [URL], in winDir: URL) -> Bool {
        guard let witness = modules.first(where: { $0.lastPathComponent == "d3d11.dll" }) ?? modules.first
        else { return false }
        return fileManager.contentsEqual(
            atPath: witness.path,
            andPath: winDir.appendingPathComponent(witness.lastPathComponent).path)
    }

    /// The per-module copy loop shared by both overlays: each PE `.dll` into the runtime's
    /// windows-modules dir and — when the backend ships one — the matching unix `.so` (symlinks
    /// recreated via `replace`, never dereferenced) into the unix-modules dir.
    private func copyModules(_ modules: [URL], unixSource: URL, toWin winDir: URL, toUnix unixDir: URL) throws {
        for dll in modules {
            try replace(dll, in: winDir)
            let so = unixSource.appendingPathComponent(
                (dll.lastPathComponent as NSString).deletingPathExtension + ".so")
            if isSymlink(so) || fileManager.fileExists(atPath: so.path) { try replace(so, in: unixDir) }
        }
    }

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
