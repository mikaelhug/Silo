import Foundation

/// A downloaded-and-installed runtime as the settings UI + the shared install VM see it — the common
/// shape of a `WineInstall` and a `DXMTInstall` (both are `name` + `installDir` + one optional located
/// payload). `RuntimeManager` keeps returning the typed installs (BottleResolver / GPTK depend on them);
/// each maps to this via `runtimeInstall`.
public struct RuntimeInstall: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String              // directory name, usually the release tag
    public let installDir: URL
    /// The located usable payload — Wine's `wine64` binary, or DXMT's `x86_64-windows` module dir — or
    /// nil when the extracted tree didn't contain it (surfaced as an "unusable" row).
    public let artifact: URL?

    public init(name: String, installDir: URL, artifact: URL?) {
        self.name = name
        self.installDir = installDir
        self.artifact = artifact
    }

    public var displayName: String { name.replacingOccurrences(of: "-", with: " ") }
    public var isUsable: Bool { artifact != nil }
}
