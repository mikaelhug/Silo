import Foundation

/// An imported Game Porting Toolkit version on disk under the Runtimes dir.
public struct GPTKInstall: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String              // directory name, e.g. "GPTK-4.0_beta_1"
    public let installDir: URL
    /// D3DMetal DLLs injected into a game prefix's system32 (`BackendConfig.gptkLibDirPath`).
    public let gptkLibDir: URL
    public let d3dMetalFramework: URL

    public init(name: String, installDir: URL, gptkLibDir: URL, d3dMetalFramework: URL) {
        self.name = name
        self.installDir = installDir
        self.gptkLibDir = gptkLibDir
        self.d3dMetalFramework = d3dMetalFramework
    }

    public var displayName: String { name.replacingOccurrences(of: "_", with: " ") }
}
