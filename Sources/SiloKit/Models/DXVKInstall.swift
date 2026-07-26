import Foundation

/// A DXVK build installed under the Runtimes dir (downloaded from Silo's Releases, or imported by folder).
/// The DXVK counterpart of `DXMTInstall` — its payload is the `x86_64-windows` module dir Silo seeds into a
/// game prefix (`GraphicsLinker.installDXVKPrefixLoaders`).
public struct DXVKInstall: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String              // directory name, usually the release tag
    public let installDir: URL
    /// Located `lib/wine/x86_64-windows` module dir inside the extracted tree, if found (what
    /// `BackendConfig.dxvkLibDirPath` points at).
    public let libDir: URL?

    public init(name: String, installDir: URL, libDir: URL?) {
        self.name = name
        self.installDir = installDir
        self.libDir = libDir
    }

    public var displayName: String { name.replacingOccurrences(of: "-", with: " ") }
    public var isUsable: Bool { libDir != nil }

    /// The backend-agnostic view used by the shared runtime-install VM + settings list (payload = the
    /// `x86_64-windows` module dir).
    public var runtimeInstall: RuntimeInstall {
        RuntimeInstall(name: name, installDir: installDir, artifact: libDir)
    }
}
