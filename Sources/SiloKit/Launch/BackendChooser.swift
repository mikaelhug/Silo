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
/// **One signal, three decisions.** The forward choice and both reactive gates read the SAME `D3DProfile`
/// (scanned once per launch from the game's exe *and* its DLLs — see `D3DProfile.scan`), so they can never
/// disagree about what the game needs. All three functions here are **pure**; the caller does the I/O.
enum BackendChooser {
    /// The backend a launch should use for `choice`, given the game's bitness, its `D3DProfile`, and any
    /// reactively-`learned` hint. A user's explicit pin always wins; a DX9-only Automatic game goes to DXVK
    /// (the only DX9 translator — bitness-independent); else a 32-bit Automatic game must use DXMT/DXVK (GPTK
    /// is 64-bit-only); else a 64-bit Automatic game uses the learned hint if one exists, else GPTK. Pure —
    /// the caller supplies the pre-read signals (a stale hint from a superseded GPTK runtime is passed as
    /// `nil` so GPTK is re-probed).
    static func choose(
        _ choice: GraphicsChoice, is32Bit: Bool, profile: D3DProfile = D3DProfile(),
        learned: GraphicsBackend? = nil
    ) -> GraphicsBackend {
        if let explicit = choice.explicitBackend { return explicit }   // a user pin always wins
        if profile.isD3D9Only { return .dxvk }                         // only DXVK translates DirectX 9
        // A Vulkan-native game needs no translation — but it DOES need a working Vulkan driver, and the wine
        // runtime bundles the stock MoltenVK that can't drive Vulkan clients properly. Routing it to the DXVK
        // backend is what puts the DXVK runtime's own MoltenVK first on the launch DYLD path.
        if profile.isVulkanNative { return .dxvk }
        // A 32-bit game that touches d3d9 AT ALL can only be served by DXVK. GPTK is 64-bit-only, so the
        // choice here is DXMT vs DXVK — and DXVK strictly dominates: it translates d3d9 *and* d3d10/11, while
        // DXMT has no d3d9 whatsoever and would silently leave that half on wined3d. Unlike the 64-bit case
        // there is no cost to preferring it, since GPTK isn't a candidate either way.
        //
        // This is NOT covered by `isD3D9Only`, which requires the profile to be free of d3d10/11 — a bar real
        // DirectX 9 games fail. Alien Swarm ships `bin/shaderapidx10.dll` (Source's experimental, unused DX10
        // shader API) which imports both d3d9 and d3d10core, so the DX9 gate refused and Automatic sent a
        // DirectX 9 game to a backend that cannot render it. Found by running the report against real games.
        if is32Bit && profile.usesD3D9 { return .dxvk }
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

    /// Whether reactively switching a GPTK-failed game to DXMT could plausibly help. Fail-**open**: an
    /// `isUnknown` profile (a dynamic `LoadLibrary` loader, or a packed binary — common) returns `true` so
    /// DXMT still gets a chance. Only suppresses the switch when we're CONFIDENT DXMT can't help: the game
    /// needs D3D12 (DXMT has none), or is DX9-only (DXMT has no d3d9 — that game belongs on DXVK).
    static func dxmtMightHelp(profile: D3DProfile) -> Bool {
        if profile.isUnknown { return true }        // unknown → let DXMT try
        if profile.isOpenGLOnly { return false }    // OpenGL — no backend translates it
        if profile.isD3D8Only { return false }      // DX8 → nothing translates it; wined3d is correct
        if profile.usesD3D12 { return false }       // needs D3D12 → GPTK is the only Metal path
        if profile.isD3D9Only { return false }      // DX9-only → DXMT can't; DXVK is the answer
        return true
    }

    /// Whether reactively switching a failed game to DXVK could plausibly help — the broadest net (DXVK covers
    /// D3D9/10/11). Fail-**open**; only suppressed when the game needs D3D12 and nothing DXVK can translate.
    /// Unlike `dxmtMightHelp` there is no D3D9 exclusion — DXVK is exactly the DirectX 9 path.
    static func dxvkMightHelp(profile: D3DProfile) -> Bool {
        if profile.isUnknown { return true }                                    // unknown → let DXVK try
        if profile.isOpenGLOnly { return false }                                // OpenGL — none translate it
        if profile.isD3D8Only { return false }                                  // DX8 → wined3d is correct
        if profile.usesD3D12, !profile.usesD3D1x, !profile.usesD3D9 { return false }   // pure D3D12 → can't
        return true
    }
}
