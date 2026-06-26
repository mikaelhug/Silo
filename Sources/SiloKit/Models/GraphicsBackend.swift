import Foundation

/// Graphics translation backend used to launch a game in its isolated prefix.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Game Porting Toolkit / D3DMetal — the primary backend.
    case gptk
    /// CrossOver's bundled wine + translation — the fallback backend.
    case crossover

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gptk: "Game Porting Toolkit (D3DMetal)"
        case .crossover: "CrossOver"
        }
    }
}
