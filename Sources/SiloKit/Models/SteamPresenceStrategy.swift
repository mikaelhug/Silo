import Foundation

/// How an isolated game prefix satisfies a game's expectation that Steam is present.
///
/// An isolated game prefix can't see an external Steam client (Steam IPC is prefix-scoped), so each
/// game picks a strategy to satisfy titles that expect Steam.
public enum SteamPresenceStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Game needs no Steam presence.
    case none
    /// Write `steam_appid.txt` next to the exe (works for many non-DRM titles). Default.
    case steamAppIDFile
    /// Symlink a shared Steam client into the prefix + run a background `steam.exe`. **Inert post-pivot**
    /// (no Master bottle to source a client from); kept for Codable compatibility + future use, and hidden
    /// from the picker via `userSelectable`.
    case sharedSteamClient
    /// Copy a user-provided Steam-API emulator stub next to the exe (owned games only; legal caveat).
    case emulatorStub

    public var id: String { rawValue }

    /// Strategies offered in the per-game settings picker (excludes the currently-inert shared client).
    public static var userSelectable: [SteamPresenceStrategy] { allCases.filter { $0 != .sharedSteamClient } }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .steamAppIDFile: "steam_appid.txt"
        case .sharedSteamClient: "Shared Steam client"
        case .emulatorStub: "Steam-API emulator stub"
        }
    }
}
