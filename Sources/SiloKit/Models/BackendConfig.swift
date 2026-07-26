import Foundation

/// Global runtime configuration: where the wine/GPTK binaries live and the signed-in Steam account.
public struct BackendConfig: Codable, Sendable, Hashable {
    /// Primary wine binary used to launch games (GPTK build).
    public var wineBinaryPath: URL?
    /// Name of the default Wine install (managed in the Wine settings tab).
    public var wineRuntimeName: String?
    /// Directory containing GPTK / D3DMetal libraries, overlaid into the wine runtime's `lib/wine` tree
    /// by `GraphicsLinker.overlayGPTK`.
    public var gptkLibDirPath: URL?
    /// Name of the default GPTK install (managed in the GPTK settings tab).
    public var gptkRuntimeName: String?
    /// Directory containing DXMT's PE modules (`d3d11`/`dxgi`/`d3d10core`/`winemetal`), overlaid into the
    /// wine runtime's `lib/wine` tree by `GraphicsLinker.overlayDXMT`. The DXMT counterpart of `gptkLibDirPath`.
    public var dxmtLibDirPath: URL?
    /// Name of the default DXMT install (managed in the Runtimes settings).
    public var dxmtRuntimeName: String?
    /// Directory containing DXVK's PE modules (`d3d9`/`d3d10core`/`d3d11`), overlaid into the wine runtime's
    /// `lib/wine` tree by `GraphicsLinker.overlayDXVK`. The DXVK counterpart of `dxmtLibDirPath`; points at
    /// the `x86_64-windows` tree (its `i386-windows` sibling drives 32-bit games — see `dxvkSupports32Bit`).
    public var dxvkLibDirPath: URL?
    /// Name of the default DXVK install (managed in the Runtimes settings).
    public var dxvkRuntimeName: String?
    /// macOS Retina/HiDPI mode ("High Resolution Mode") for the shared Steam bottle. Mirrors what Silo last
    /// wrote to the prefix; off is Wine's default. Drives a coupled PAIR of registry keys —
    /// `HKCU\Software\Wine\Mac Driver\RetinaMode` (crisp native rendering) plus its DPI companion
    /// `HKCU\Control Panel\Desktop\LogPixels` (192 so the UI isn't tiny) — see `WineTools.setRetinaMode`.
    public var retinaMode: Bool

    public init(
        wineBinaryPath: URL? = nil,
        wineRuntimeName: String? = nil,
        gptkLibDirPath: URL? = nil,
        gptkRuntimeName: String? = nil,
        dxmtLibDirPath: URL? = nil,
        dxmtRuntimeName: String? = nil,
        dxvkLibDirPath: URL? = nil,
        dxvkRuntimeName: String? = nil,
        retinaMode: Bool = false
    ) {
        self.wineBinaryPath = wineBinaryPath
        self.wineRuntimeName = wineRuntimeName
        self.gptkLibDirPath = gptkLibDirPath
        self.gptkRuntimeName = gptkRuntimeName
        self.dxmtLibDirPath = dxmtLibDirPath
        self.dxmtRuntimeName = dxmtRuntimeName
        self.dxvkLibDirPath = dxvkLibDirPath
        self.dxvkRuntimeName = dxvkRuntimeName
        self.retinaMode = retinaMode
    }

    private enum CodingKeys: String, CodingKey {
        case wineBinaryPath, wineRuntimeName, gptkLibDirPath, gptkRuntimeName
        case dxmtLibDirPath, dxmtRuntimeName, dxvkLibDirPath, dxvkRuntimeName, retinaMode
    }

    /// Tolerant decode (mirrors `AppState`): every field defaults if absent, so adding one never makes an
    /// old `config.json` undecodable — which would otherwise discard the whole document on load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wineBinaryPath = try c.decodeIfPresent(URL.self, forKey: .wineBinaryPath)
        wineRuntimeName = try c.decodeIfPresent(String.self, forKey: .wineRuntimeName)
        gptkLibDirPath = try c.decodeIfPresent(URL.self, forKey: .gptkLibDirPath)
        gptkRuntimeName = try c.decodeIfPresent(String.self, forKey: .gptkRuntimeName)
        dxmtLibDirPath = try c.decodeIfPresent(URL.self, forKey: .dxmtLibDirPath)
        dxmtRuntimeName = try c.decodeIfPresent(String.self, forKey: .dxmtRuntimeName)
        dxvkLibDirPath = try c.decodeIfPresent(URL.self, forKey: .dxvkLibDirPath)
        dxvkRuntimeName = try c.decodeIfPresent(String.self, forKey: .dxvkRuntimeName)
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? false
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }

    /// The lib dir overlaid for a given backend — the single place that maps a `GraphicsBackend` to its
    /// configured runtime modules, so `makePlan` and the linker never hard-code one backend's path.
    public func libDir(for backend: GraphicsBackend) -> URL? {
        switch backend {
        case .gptk: gptkLibDirPath
        case .dxmt: dxmtLibDirPath
        case .dxvk: dxvkLibDirPath
        }
    }

    /// Whether the installed DXMT runtime ships 32-bit (i386) modules — a 32-bit game can ONLY run on DXMT if
    /// so (GPTK is 64-bit-only). `dxmtLibDirPath` points at the `x86_64-windows` tree, so this checks its
    /// `i386-windows` sibling for `winemetal.dll` (the load-bearing DXMT builtin). False when DXMT is unset.
    public var dxmtSupports32Bit: Bool {
        guard let lib = dxmtLibDirPath else { return false }
        let i386 = lib.deletingLastPathComponent()
            .appendingPathComponent("i386-windows/winemetal.dll")
        return FileManager.default.fileExists(atPath: i386.path)
    }

    /// Whether the installed DXVK runtime ships 32-bit (i386) modules — DXVK is the ONLY backend that can run
    /// a 32-bit **DirectX 9** game (GPTK is 64-bit-only; DXMT has no d3d9), so this gates that path. Mirrors
    /// `dxmtSupports32Bit`, checking the `i386-windows` sibling for `d3d11.dll` (the DXVK witness module).
    /// False when DXVK is unset.
    public var dxvkSupports32Bit: Bool {
        guard let lib = dxvkLibDirPath else { return false }
        let i386 = lib.deletingLastPathComponent()
            .appendingPathComponent("i386-windows/d3d11.dll")
        return FileManager.default.fileExists(atPath: i386.path)
    }
}
