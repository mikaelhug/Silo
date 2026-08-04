import Foundation

/// Resolves a per-game `GraphicsChoice` to a concrete `GraphicsBackend` at launch — the "Automatic" brain.
///
/// **Policy (decided 2026-07-13): GPTK is treated as always the faster/preferred backend, so it is used
/// unless it structurally can't (32-bit — Apple ships no i386 D3DMetal → DXMT) or is proven not to run the
/// game.** DXMT is strictly a fallback, never a co-equal choice — there is no per-title "which is faster"
/// ranking because GPTK is defined to win. GPTK titles that fail to engage are learned reactively
/// (`GameLibraryViewModel` records a `learnedBackend` hint — kept separate from the user's `.auto` so it stays
/// re-evaluable and re-probes GPTK after a runtime upgrade), which `choose` consults for the next launch, so
/// Automatic adapts without a per-title database.
///
/// **DirectX 9 (added 2026-07-26): the ONE exception to GPTK-first.** GPTK doesn't translate DX9 at all and
/// DXMT is D3D10/11-only, so a DX9-only title has no Metal backend — it would silently fall to wine's wined3d
/// and usually black-screen. DXVK (D3D9→Vulkan→MoltenVK) is its only translator, so an Automatic DX9-only game
/// is routed straight to **DXVK** (bitness-independent — DXVK ships both ABIs). DXVK is also the deepest
/// reactive fallback for the DX10/11 long tail (GPTK → DXMT → DXVK). OpenGL titles still run on wine's own GL.
///
/// `choose` is pure (pre-computed bitness + DX9 flag + learned hint); `dxmtMightHelp`/`dxvkMightHelp`/
/// `isD3D9Only` read the import table.
enum BackendChooser {
    /// DLLs whose translation DXMT provides (so a GPTK failure on one of these is worth retrying on DXMT).
    private static let dxmtTranslatable: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    /// DLLs no current backend but GPTK can translate — DXMT/DXVK are pointless for these.
    private static let d3d12: Set<String> = ["d3d12.dll", "d3d12core.dll"]

    /// The backend a launch should use for `choice`, given the game's bitness, whether it's a DX9-only title
    /// (both from `WindowsExecutable`), and any reactively-`learned` hint. A user's explicit pin always wins;
    /// a DX9-only Automatic game goes to DXVK (the only DX9 translator — bitness-independent); else a 32-bit
    /// Automatic game must use DXMT (GPTK is 64-bit-only); else a 64-bit Automatic game uses the learned hint
    /// if one exists, else GPTK. Pure — the caller supplies the pre-read signals (a stale hint from a
    /// superseded GPTK runtime is passed as `nil` so GPTK is re-probed).
    static func choose(
        _ choice: GraphicsChoice, is32Bit: Bool, isD3D9Only: Bool = false, learned: GraphicsBackend? = nil
    ) -> GraphicsBackend {
        if let explicit = choice.explicitBackend { return explicit }   // a user pin always wins
        if isD3D9Only { return .dxvk }                                 // only DXVK translates DirectX 9
        if is32Bit {
            // GPTK is 64-bit-only (Apple ships no i386 D3DMetal), so a 32-bit game can only run on DXMT or
            // DXVK — and BOTH ship i386 modules. A learned hint between those two MUST be honored: a 32-bit
            // title DXMT can't drive reactively learns `.dxvk`, and ignoring that here would route it back to
            // DXMT every launch, forever, while the UI kept promising DXVK. A `.gptk` hint is never valid
            // for 32-bit, so it falls through to DXMT.
            if let learned, learned != .gptk { return learned }
            return .dxmt
        }
        return learned ?? .gptk                                        // 64-bit Automatic: learned hint, else GPTK
    }

    /// Whether an Automatic game should route to DXVK up front: it imports `d3d9` and NONE of D3D10/11/12 —
    /// a pure DirectX 9 title, which neither GPTK nor DXMT can translate. Conservative (a game that ALSO
    /// imports d3d11 stays on the GPTK/DXMT path, where DXVK's extra Vulkan→Metal hop isn't worth it). A read
    /// of the PE import table (regular + delay-load); fail-**closed** — an unreadable/import-less exe is NOT
    /// treated as DX9-only (it takes the normal GPTK-first path).
    static func isD3D9Only(exe: URL) -> Bool {
        let imports = WindowsExecutable.importedDLLs(of: exe)
        guard imports.contains("d3d9.dll") else { return false }
        return imports.isDisjoint(with: dxmtTranslatable) && imports.isDisjoint(with: d3d12)
    }

    /// Whether reactively switching a GPTK-failed game to DXMT could plausibly help. Fail-**open**: an exe
    /// with no static Direct3D imports (dynamic `LoadLibrary` loaders — common) returns `true` so DXMT still
    /// gets a chance. Only suppresses the switch when we're CONFIDENT DXMT can't help: the exe imports D3D12
    /// (DXMT has no d3d12), or imports D3D9 and NONE of D3D10/11 (DXMT has no d3d9).
    static func dxmtMightHelp(exe: URL) -> Bool {
        let imports = WindowsExecutable.importedDLLs(of: exe)
        if imports.isEmpty { return true }                                  // unknown → let DXMT try
        if !imports.isDisjoint(with: d3d12) { return false }                // needs D3D12 → GPTK only
        let usesD3D1x = !imports.isDisjoint(with: dxmtTranslatable)
        if imports.contains("d3d9.dll"), !usesD3D1x { return false }        // D3D9-only → DXMT can't
        return true
    }

    /// Whether reactively switching a failed game to DXVK could plausibly help — the broadest net (DXVK covers
    /// D3D9/10/11). Fail-**open**; only suppressed when the exe imports D3D12 and nothing DXVK can translate
    /// (DXVK has no d3d12). Unlike `dxmtMightHelp` there is no D3D9 exclusion — DXVK is exactly the D3D9 path.
    static func dxvkMightHelp(exe: URL) -> Bool {
        let imports = WindowsExecutable.importedDLLs(of: exe)
        if imports.isEmpty { return true }                                  // unknown → let DXVK try
        if !imports.isDisjoint(with: d3d12), imports.isDisjoint(with: dxmtTranslatable),
           !imports.contains("d3d9.dll") { return false }                   // pure D3D12 → DXVK can't
        return true
    }
}
