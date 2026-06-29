import Foundation

/// A non-Steam game the user added by hand: an absolute path to a Windows `.exe` on disk, launched in the
/// shared Steam bottle under GPTK (no Steamworks needed). Unlike `SteamApp` — which is *discovered* from
/// the bottle's `appmanifest_*.acf` — a `ManualGame` is user-authored and persisted in `config.json`.
public struct ManualGame: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    /// Absolute host path to the game executable — typically inside the bottle's `drive_c` after running
    /// the game's installer, or a portable `.exe` anywhere readable. Wine launches host paths directly.
    public var executablePath: URL
    /// Per-game performance + environment tuning (same knobs as a Steam game). Defaults are the
    /// Apple-Silicon GPTK baseline.
    public var envFlags: EnvFlags
    /// Extra arguments appended after the executable.
    public var customArgs: [String]
    public var lastPlayed: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        executablePath: URL,
        envFlags: EnvFlags = EnvFlags(),
        customArgs: [String] = [],
        lastPlayed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.envFlags = envFlags
        self.customArgs = customArgs
        self.lastPlayed = lastPlayed
    }

    /// The directory containing the executable — the launch working directory and "Show in Finder" target.
    public var installLocation: URL { executablePath.deletingLastPathComponent() }

    /// Single-field, space-separated view of `customArgs` for a Steam-style launch-options editor
    /// (splits on whitespace, drops empties; quoting unsupported, matching `GameConfig`).
    public var launchOptionsString: String {
        get { customArgs.joined(separator: " ") }
        set { customArgs = newValue.split(whereSeparator: \.isWhitespace).map(String.init) }
    }
}
