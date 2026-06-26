import Foundation

/// A Wine build installed under the Runtimes dir (downloaded via the Wine Manager).
public struct WineInstall: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String              // directory name, usually the release tag
    public let installDir: URL
    /// Located `wine64`/`wine` loader inside the extracted tree, if found.
    public let wineBinary: URL?

    public init(name: String, installDir: URL, wineBinary: URL?) {
        self.name = name
        self.installDir = installDir
        self.wineBinary = wineBinary
    }

    public var displayName: String { name.replacingOccurrences(of: "-", with: " ") }
    public var isUsable: Bool { wineBinary != nil }
}
