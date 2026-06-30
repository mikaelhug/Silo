import Foundation

/// A DXMT build installed under the Runtimes dir (downloaded from Silo's Releases, or imported by folder).
/// The DXMT counterpart of `WineInstall`.
public struct DXMTInstall: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String              // directory name, usually the release tag
    public let installDir: URL
    /// Located `lib/wine/x86_64-windows` module dir inside the extracted tree, if found (what
    /// `BackendConfig.dxmtLibDirPath` points at).
    public let libDir: URL?

    public init(name: String, installDir: URL, libDir: URL?) {
        self.name = name
        self.installDir = installDir
        self.libDir = libDir
    }

    public var displayName: String { name.replacingOccurrences(of: "-", with: " ") }
    public var isUsable: Bool { libDir != nil }
}
