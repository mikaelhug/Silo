import Foundation

/// Resolves a per-game `GraphicsChoice` to a concrete `GraphicsBackend` at launch — the "Automatic" brain.
/// Pure + table-tested (the only I/O is reading the game binary's headers, which fails open).
///
/// The automatic strategy is intentionally conservative: **GPTK first** (Apple's proven layer, and the only
/// one that covers D3D12), except where GPTK structurally can't run the game (32-bit — Apple ships no i386
/// D3DMetal → DXMT). GPTK titles that fail to engage are learned reactively (`GameLibraryViewModel.play`
/// persists `.dxmt` for next time), so Automatic adapts without a per-title database. DirectX 9 / OpenGL
/// titles need neither backend — they run on Wine's own wined3d/GL under whatever runtime is active.
enum BackendChooser {
    /// DLLs whose translation DXMT provides (so a GPTK failure on one of these is worth retrying on DXMT).
    private static let dxmtTranslatable: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    /// DLLs no current backend but GPTK can translate — DXMT is pointless for these.
    private static let d3d12: Set<String> = ["d3d12.dll", "d3d12core.dll"]

    /// The backend a launch should use for `choice`, consulting the game binary for `.auto`.
    static func choose(_ choice: GraphicsChoice, exe: URL?) -> GraphicsBackend {
        if let explicit = choice.explicitBackend { return explicit }
        // Automatic: GPTK is 64-bit-only, so a 32-bit game must use DXMT; everything else starts on GPTK.
        if let exe, WindowsExecutable.is32Bit(exe) { return .dxmt }
        return .gptk
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
