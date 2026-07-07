import Foundation

/// A wine PE module ABI. Wine keeps builtin DLLs in a per-Windows-arch tree and picks the tree that
/// matches the running executable's PE machine type — so a graphics overlay that populates BOTH trees is
/// selected automatically per game (64-bit game → `x86_64-windows`, 32-bit game → `i386-windows`), with no
/// runtime detection on Silo's side. The unix `.so` side is host-arch only (new-WoW64: one `x86_64-unix`
/// shared by both PE arches), so there is no `i386-unix` to maintain.
public enum WineArch: String, Sendable, CaseIterable {
    case x86_64
    case i386
}

/// The on-disk layout of a Silo wine runtime (`<root>/bin/wine64`, `<root>/lib/...`). Mirrors
/// `PrefixLayout` for the runtime side so the structure lives in one place.
public struct WineRuntimeLayout: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    /// From a wine binary at `<root>/bin/wine[64]`.
    public init(wineBinary: URL) { self.init(root: wineBinary.deletingLastPathComponent().deletingLastPathComponent()) }
    public var bundledDylibDir: URL { root.appendingPathComponent("lib/silo-bundled", isDirectory: true) }
    public var externalDir: URL { root.appendingPathComponent("lib/external", isDirectory: true) }
    /// The builtin PE modules dir for a given ABI (`lib/wine/<arch>-windows`).
    public func windowsModulesDir(_ arch: WineArch = .x86_64) -> URL {
        root.appendingPathComponent("lib/wine/\(arch.rawValue)-windows", isDirectory: true)
    }
    /// The unix `.so` modules dir for a given ABI (`lib/wine/<arch>-unix`). Under new-WoW64 only
    /// `x86_64-unix` exists; the i386 PE side thunks into it.
    public func unixModulesDir(_ arch: WineArch = .x86_64) -> URL {
        root.appendingPathComponent("lib/wine/\(arch.rawValue)-unix", isDirectory: true)
    }
    // Back-compat aliases for the common (64-bit) case.
    public var windowsModulesDir: URL { windowsModulesDir(.x86_64) }
    public var unixModulesDir: URL { unixModulesDir(.x86_64) }
    public var wrapperExe: URL { root.appendingPathComponent("share/silo/steamwebhelper-wrapper.exe") }
    /// The runtime's `wineserver` (next to the wine loader) — used to settle a prefix's server after boot.
    public var wineserver: URL { root.appendingPathComponent("bin/wineserver") }
}
