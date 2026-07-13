import Foundation

/// Resolves a per-game `GraphicsChoice` to a concrete `GraphicsBackend` at launch — the "Automatic" brain.
///
/// **Policy (decided 2026-07-13): GPTK is treated as always the faster/preferred backend, so it is used
/// unless it structurally can't (32-bit — Apple ships no i386 D3DMetal → DXMT) or is proven not to run the
/// game.** DXMT is strictly a fallback, never a co-equal choice — there is no per-title "which is faster"
/// ranking because GPTK is defined to win. GPTK titles that fail to engage are learned reactively
/// (`GameLibraryViewModel` records a `learnedBackend` hint — kept separate from the user's `.auto` so it stays
/// re-evaluable and re-probes GPTK after a runtime upgrade), which `choose` consults for the next launch, so
/// Automatic adapts without a per-title database. DirectX 9 / OpenGL titles need neither backend — they run on
/// Wine's own wined3d/GL under whatever runtime is active.
///
/// `choose` is pure (takes the pre-computed bitness + learned hint); `dxmtMightHelp` reads the import table.
enum BackendChooser {
    /// DLLs whose translation DXMT provides (so a GPTK failure on one of these is worth retrying on DXMT).
    private static let dxmtTranslatable: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    /// DLLs no current backend but GPTK can translate — DXMT is pointless for these.
    private static let d3d12: Set<String> = ["d3d12.dll", "d3d12core.dll"]

    /// The backend a launch should use for `choice`, given the game's bitness (from `WindowsExecutable`) and
    /// any reactively-`learned` hint. A user's explicit pin always wins; a 32-bit Automatic game must use
    /// DXMT (GPTK is 64-bit-only), which moots the hint; a 64-bit Automatic game uses the learned hint if one
    /// exists, else GPTK. Pure — the caller supplies bitness and a runtime-validated hint (a stale hint from a
    /// superseded GPTK runtime is passed as `nil` so GPTK is re-probed).
    static func choose(_ choice: GraphicsChoice, is32Bit: Bool, learned: GraphicsBackend? = nil) -> GraphicsBackend {
        if let explicit = choice.explicitBackend { return explicit }   // a user pin always wins
        if is32Bit { return .dxmt }                                    // GPTK is 64-bit-only; learned is moot
        return learned ?? .gptk                                        // 64-bit Automatic: learned hint, else GPTK
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
}
