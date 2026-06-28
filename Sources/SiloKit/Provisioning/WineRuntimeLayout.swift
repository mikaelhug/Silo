import Foundation
/// The on-disk layout of a Silo wine runtime (`<root>/bin/wine64`, `<root>/lib/...`). Mirrors
/// `PrefixLayout` for the runtime side so the structure lives in one place.
public struct WineRuntimeLayout: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    /// From a wine binary at `<root>/bin/wine[64]`.
    public init(wineBinary: URL) { self.init(root: wineBinary.deletingLastPathComponent().deletingLastPathComponent()) }
    public var bundledDylibDir: URL { root.appendingPathComponent("lib/silo-bundled", isDirectory: true) }
    public var externalDir: URL { root.appendingPathComponent("lib/external", isDirectory: true) }
    public var windowsModulesDir: URL { root.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true) }
    public var unixModulesDir: URL { root.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true) }
    public var wrapperExe: URL { root.appendingPathComponent("share/silo/steamwebhelper-wrapper.exe") }
}
