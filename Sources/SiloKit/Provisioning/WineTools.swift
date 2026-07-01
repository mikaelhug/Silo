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

    /// macOS Retina/HiDPI mode for `prefix` — `HKCU\Software\Wine\Mac Driver\RetinaMode` = `y`/`n`.
    /// On = Wine reports the real Retina resolution to games (crisp output, but in-game UI can render
    /// small); off (Wine's default) = a non-Retina/scaled mode. The standard fix for wrong-sized windows.
    public func setRetinaMode(_ on: Bool, prefix: URL, wine: URL) async throws {
        try await setRegistryValue(
            on ? "y" : "n", name: "RetinaMode", type: "REG_SZ",
            at: #"HKCU\Software\Wine\Mac Driver"#, prefix: prefix, wine: wine)
    }

    /// Base wine env + the co-residency msync rule so the command shares the bottle's wineserver.
    private func environment(prefix: URL, wine: URL) -> [String: String] {
        Silo.msyncWineEnvironment(prefix: prefix, wine: wine)
    }
}
