import Foundation

/// How a game satisfies its expectation that Steam is present. In the bottle model a real Steam client is
/// already co-resident, so the default (`.steamAppIDFile`) is usually enough; this stays per-game for the
/// rare title that needs more.
public enum SteamPresenceStrategy: String, Sendable, CaseIterable, Identifiable {
    /// Game needs no Steam presence.
    case none
    /// Write `steam_appid.txt` next to the exe (enough for most games co-resident with the bottle's Steam).
    case steamAppIDFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .steamAppIDFile: "steam_appid.txt"
        }
    }
}

extension SteamPresenceStrategy: Codable {
    // Decode unknown/removed raw values (the dropped Goldberg `emulatorStub` or `sharedSteamClient`) to
    // `.none` so an old saved config never fails to load.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SteamPresenceStrategy(rawValue: raw) ?? .none
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
