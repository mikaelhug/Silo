import Foundation

/// How an isolated game prefix satisfies a game's expectation that Steam is present.
///
/// An isolated game prefix can't see an external Steam client (Steam IPC is prefix-scoped), so each
/// game picks a strategy to satisfy titles that expect Steam.
public enum SteamPresenceStrategy: String, Sendable, CaseIterable, Identifiable {
    /// Game needs no Steam presence.
    case none
    /// Write `steam_appid.txt` next to the exe (works for many non-DRM titles). Default.
    case steamAppIDFile
    /// Run a real Steam client co-resident in the game's prefix (the only correct way to satisfy a
    /// Steamworks/DRM game — online features intact). Not yet implemented; hidden from the picker.
    case sharedSteamClient

    public var id: String { rawValue }

    /// Strategies offered in the per-game settings picker (excludes the not-yet-implemented client).
    public static var userSelectable: [SteamPresenceStrategy] { allCases.filter { $0 != .sharedSteamClient } }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .steamAppIDFile: "steam_appid.txt"
        case .sharedSteamClient: "Steam client (in prefix)"
        }
    }
}

extension SteamPresenceStrategy: Codable {
    // Decode unknown/removed raw values (e.g. the dropped Goldberg `emulatorStub`) to `.none` so an old
    // saved config never fails to load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SteamPresenceStrategy(rawValue: raw) ?? .none
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
