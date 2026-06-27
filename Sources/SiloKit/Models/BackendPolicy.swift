import Foundation

/// Pure, side-effect-free rules for choosing a game's graphics backend.
///
/// Apple's GPTK / D3DMetal translates **DirectX 9 through 12** (including ray tracing) to Metal and is
/// the most capable path on Apple Silicon, so it's the recommended default for essentially every Windows
/// DirectX game. CrossOver (wine + DXVK) is the fallback — used automatically when GPTK isn't installed,
/// and a sensible manual choice for the rare title that misbehaves under D3DMetal.
public enum BackendPolicy {

    /// The recommended backend for a game given its DirectX needs and which runtimes are installed.
    /// (DirectX 9–12 are all GPTK territory; the version only shapes the human-readable rationale.)
    public static func recommended(
        directXVersion: Int?, gptkInstalled: Bool, crossoverInstalled: Bool
    ) -> GraphicsBackend {
        if gptkInstalled { return .gptk }
        if crossoverInstalled { return .crossover }
        return .gptk
    }

    /// The backend to *actually* launch with: honour the user's choice, but fall back when the requested
    /// runtime isn't installed — so a `.gptk` config on a machine without GPTK still launches (CrossOver)
    /// instead of running with no DirectX translation at all.
    public static func effective(
        requested: GraphicsBackend, gptkInstalled: Bool, crossoverInstalled: Bool
    ) -> GraphicsBackend {
        switch requested {
        case .gptk: return gptkInstalled ? .gptk : (crossoverInstalled ? .crossover : .gptk)
        case .crossover: return crossoverInstalled ? .crossover : (gptkInstalled ? .gptk : .crossover)
        }
    }

    /// One-line rationale for the recommended backend, shown in the UI so the choice is transparent.
    public static func rationale(directXVersion: Int?, recommended: GraphicsBackend) -> String {
        let dx = directXVersion.map { "DirectX \($0)" } ?? "DirectX"
        switch recommended {
        case .gptk: return "\(dx) → Game Porting Toolkit (D3DMetal) handles DirectX 9–12 best on Apple Silicon."
        case .crossover: return "\(dx) → CrossOver (DXVK) — GPTK isn't installed, so this is the fallback."
        }
    }
}
