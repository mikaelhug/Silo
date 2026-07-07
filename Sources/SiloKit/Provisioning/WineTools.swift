import Foundation

/// Writes small registry edits inside a given prefix — the registry tweaks Silo drives itself, currently
/// Retina/HiDPI mode. (Launching Wine's GUI maintenance tools — winecfg/regedit/Control Panel — is
/// `LaunchOrchestrator.runWineTool`.) All execution goes through `ProcessRunning`, so it unit-tests with
/// no Wine installed.
///
/// A registry write runs with `WINEMSYNC=1` (Silo's sync mode) so it attaches to the bottle's *existing*
/// wineserver rather than forking a second one on the same prefix — the co-residency rule — and runs to
/// completion so the caller knows it landed before (re)launching the game.
public struct WineTools: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning) { self.runner = runner }

    public enum ToolsError: Error, Sendable, Equatable { case registryWriteFailed(Int32) }

    /// Write a single registry value via `wine reg add … /f` (overwrites; runs to completion).
    public func setRegistryValue(
        _ data: String, name: String, type: String, at key: String, prefix: URL, wine: URL
    ) async throws {
        let result = try await runner.run(
            executable: wine,
            arguments: ["reg", "add", key, "/v", name, "/t", type, "/d", data, "/f"],
            environment: environment(prefix: prefix, wine: wine), currentDirectory: nil)
        guard result.succeeded else { throw ToolsError.registryWriteFailed(result.exitCode) }
    }

    /// macOS Retina/HiDPI mode for `prefix` — CrossOver's "High Resolution Mode", written as a **pair** so
    /// the two halves can never drift:
    /// - `HKCU\Software\Wine\Mac Driver\RetinaMode` = `y`/`n` — on = Wine renders at the real Retina
    ///   (backing-pixel) resolution, so output is crisp instead of pixel-doubled.
    /// - `HKCU\Control Panel\Desktop\LogPixels` = `192`/`96` — the DPI companion. RetinaMode alone doubles
    ///   the pixel count, which makes in-game/UI text render tiny; 192 DPI (200%) tells Windows apps to scale
    ///   UI up to match, keeping it legible. This is exactly what CrossOver reports (192 DPI) alongside its
    ///   High Resolution Mode. LogPixels is meaningless without RetinaMode — 192 DPI on a non-Retina bottle
    ///   would just bloat the UI — so it is ONLY ever written here, coupled to RetinaMode's state, reverting
    ///   to Wine's default 96 (100%) when off.
    /// The standard fix for wrong-sized game windows on Retina Macs; takes effect on the next launch.
    public func setRetinaMode(_ on: Bool, prefix: URL, wine: URL) async throws {
        try await setRegistryValue(
            on ? "y" : "n", name: "RetinaMode", type: "REG_SZ",
            at: #"HKCU\Software\Wine\Mac Driver"#, prefix: prefix, wine: wine)
        try await setRegistryValue(
            on ? "192" : "96", name: "LogPixels", type: "REG_DWORD",
            at: #"HKCU\Control Panel\Desktop"#, prefix: prefix, wine: wine)
    }

    /// Base wine env + the co-residency msync rule so the command shares the bottle's wineserver.
    private func environment(prefix: URL, wine: URL) -> [String: String] {
        Silo.msyncWineEnvironment(prefix: prefix, wine: wine)
    }
}
