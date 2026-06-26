import Foundation

/// How an isolated game prefix satisfies a game's expectation that Steam is present.
///
/// The Master bottle cannot project Steam presence into an isolated prefix (Steam IPC is
/// prefix-scoped), so each game picks a strategy.
public enum SteamPresenceStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Game needs no Steam presence.
    case none
    /// Write `steam_appid.txt` next to the exe (works for many non-DRM titles). Default.
    case steamAppIDFile
    /// Symlink the Master Steam client into the prefix + run a background `steam.exe` there.
    case sharedSteamClient
    /// Copy a user-provided Steam-API emulator stub next to the exe (owned games only; legal caveat).
    case emulatorStub

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .steamAppIDFile: "steam_appid.txt"
        case .sharedSteamClient: "Shared Steam client"
        case .emulatorStub: "Steam-API emulator stub"
        }
    }

    /// Whether this strategy requires the user to supply a stub file path.
    public var requiresUserStub: Bool { self == .emulatorStub }
}
