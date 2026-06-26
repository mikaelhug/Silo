import Foundation

/// A Wine/GPTK runtime that Silo manages (downloaded into the Runtimes dir, or user-supplied).
public struct WineRuntime: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Runtime root — contains `bin/`, `lib/`, etc.
    public let installPath: URL
    public let kind: Kind

    public enum Kind: String, Codable, Sendable {
        case gptk        // Game Porting Toolkit-patched wine + D3DMetal
        case crossover   // CrossOver wine
        case vanilla     // plain wine (e.g. for the simple Steam bottle)
    }

    public init(name: String, installPath: URL, kind: Kind) {
        self.name = name
        self.installPath = installPath
        self.kind = kind
    }

    public var wineBinary: URL { installPath.appendingPathComponent("bin/wine64") }
    public var wineserverBinary: URL { installPath.appendingPathComponent("bin/wineserver") }
}
