import Foundation

/// Runs Wine's GUI maintenance tools and small registry edits inside a given prefix — the user's escape
/// hatch for fixing a bottle by hand (winecfg / regedit / Control Panel) plus the registry tweaks Silo
/// drives itself (Retina/HiDPI mode). All execution goes through `ProcessRunning`, so it unit-tests with
/// no Wine installed.
///
/// Every command runs with `WINEMSYNC=1` (Silo's sync mode) so it attaches to the bottle's *existing*
/// wineserver rather than forking a second one on the same prefix — the same co-residency rule the game
/// launch path follows. GUI tools are spawned detached (they open a window); a registry write runs to
/// completion so the caller knows it landed before (re)launching the game.
public struct WineTools: Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning) { self.runner = runner }

    public enum ToolsError: Error, Sendable, Equatable { case registryWriteFailed(Int32) }

    /// The Wine maintenance tools Silo surfaces so users can fix a prefix without leaving the app.
    public enum Tool: String, Sendable, CaseIterable {
        case winecfg    // Wine configuration
        case regedit    // registry editor
        case control    // Windows Control Panel
    }

    /// Launch a Wine GUI maintenance tool in `prefix` (detached — it opens its own window). Output streams
    /// to `logURL` so a misbehaving tool still leaves a trace. Returns the child PID.
    @discardableResult
    public func open(_ tool: Tool, prefix: URL, wine: URL, logURL: URL) async throws -> Int32 {
        try await runner.spawnDetached(
            executable: wine, arguments: [tool.rawValue],
            environment: environment(prefix: prefix, wine: wine), currentDirectory: nil, logURL: logURL)
    }

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

    /// Base wine env + `WINEMSYNC=1` so the command shares the bottle's wineserver (no 2nd server fork).
    private func environment(prefix: URL, wine: URL) -> [String: String] {
        var env = Silo.wineEnvironment(prefix: prefix, wine: wine)
        env["WINEMSYNC"] = "1"
        return env
    }
}
