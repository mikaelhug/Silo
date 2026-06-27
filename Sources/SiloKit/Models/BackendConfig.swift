import Foundation

/// Global runtime configuration: where the wine/GPTK binaries live and the signed-in Steam account.
public struct BackendConfig: Codable, Sendable, Hashable {
    /// Primary wine binary used to launch games (GPTK build).
    public var wineBinaryPath: URL?
    /// Name of the default Wine install (managed in the Wine Manager).
    public var wineRuntimeName: String?
    /// Fallback wine binary (CrossOver).
    public var crossoverWinePath: URL?
    /// Directory containing GPTK / D3DMetal libraries to inject into game prefixes.
    public var gptkLibDirPath: URL?
    /// Name of the default GPTK install (managed in the GPTK Manager).
    public var gptkRuntimeName: String?
    /// Directory containing DXVK DLLs (`dxgi.dll`, `d3d11.dll`) for the CrossOver/DXVK backend.
    public var dxvkDLLDirPath: URL?
    /// Steam account name used by SteamCMD (the post-pivot downloader). Password is never stored —
    /// SteamCMD caches a refresh token after the first login.
    public var steamUsername: String?
    /// How this config was discovered.
    public var detectedSource: DetectedSource

    public enum DetectedSource: String, Codable, Sendable {
        case whisky, kegworks, crossover, manual, none
    }

    public init(
        wineBinaryPath: URL? = nil,
        wineRuntimeName: String? = nil,
        crossoverWinePath: URL? = nil,
        gptkLibDirPath: URL? = nil,
        gptkRuntimeName: String? = nil,
        dxvkDLLDirPath: URL? = nil,
        steamUsername: String? = nil,
        detectedSource: DetectedSource = .none
    ) {
        self.wineBinaryPath = wineBinaryPath
        self.wineRuntimeName = wineRuntimeName
        self.crossoverWinePath = crossoverWinePath
        self.gptkLibDirPath = gptkLibDirPath
        self.gptkRuntimeName = gptkRuntimeName
        self.dxvkDLLDirPath = dxvkDLLDirPath
        self.steamUsername = steamUsername
        self.detectedSource = detectedSource
    }

    /// Whether games can be launched (a wine binary is set).
    public var isWineConfigured: Bool { wineBinaryPath != nil }

    /// GPTK's `lib/external` dir (D3DMetal.framework + libd3dshared.dylib), derived from the injected
    /// DLL dir `<root>/lib/wine/x86_64-windows`. Must be on the launch DYLD fallback paths so GPTK's
    /// d3d unix modules resolve `@rpath/libd3dshared.dylib` and the framework at runtime.
    public var gptkExternalDirPath: URL? {
        gptkLibDirPath?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("external", isDirectory: true)
    }

    /// GPTK's `lib/wine` dir holding its builtin d3d modules (`x86_64-unix/*.so` + `x86_64-windows/*.dll`),
    /// added to `WINEDLLPATH` so wine loads GPTK's d3d/D3DMetal instead of the base wine's own.
    public var gptkWineDLLDirPath: URL? {
        gptkLibDirPath?.deletingLastPathComponent()
    }

    /// The wine binary to use for a backend, falling back to the primary when a specific one is unset.
    public func wineBinary(for backend: GraphicsBackend) -> URL? {
        switch backend {
        case .gptk: wineBinaryPath ?? crossoverWinePath
        case .crossover: crossoverWinePath ?? wineBinaryPath
        }
    }
}
