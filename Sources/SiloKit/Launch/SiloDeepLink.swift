import Foundation

/// A Silo deep link — the payload a Desktop shortcut opens to ask the running (or freshly-launched) app to
/// play a specific game. Deliberately tiny and stable: a shortcut is a *reference* to a library game, not a
/// snapshot of how to launch it, so the app resolves the backend, prefix, and Steam-client requirement fresh
/// at click time (Automatic/learned-DXMT included). Pure value type — the parser and builder are exhaustively
/// unit-tested; `SiloApp.onOpenURL` feeds incoming URLs through `init?(url:)`.
///
/// Wire format (custom URL scheme, registered in `Info.plist.template`):
///   `silo://play/steam/<appID>`   — a Steam-bottle game, by appID
///   `silo://play/manual/<uuid>`   — a manual (non-Steam) game, by its stable id
public enum SiloDeepLink: Sendable, Equatable {
    case playSteam(appID: Int)
    case playManual(id: UUID)

    /// The registered URL scheme. Must match `CFBundleURLSchemes` in `Info.plist.template`.
    public static let scheme = "silo"
    /// The single host Silo answers today; keeps room for future verbs without ambiguity.
    static let playHost = "play"

    /// Parse an incoming URL, or nil if it isn't a well-formed Silo play link. Fails closed — an unknown
    /// scheme/host/kind, a non-numeric appID, or a malformed UUID all return nil rather than a wrong target.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == Self.playHost else { return nil }
        // pathComponents includes the leading "/" element — drop it so ["/", "steam", "440"] → ["steam","440"].
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "steam":
            guard let appID = Int(parts[1]) else { return nil }
            self = .playSteam(appID: appID)
        case "manual":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .playManual(id: id)
        default:
            return nil
        }
    }

    /// The canonical URL for this link (what a shortcut's launch script passes to `open`).
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.playHost
        switch self {
        case .playSteam(let appID): components.path = "/steam/\(appID)"
        case .playManual(let id): components.path = "/manual/\(id.uuidString)"
        }
        // The path is always a valid, percent-safe URL for these fixed shapes.
        return components.url!
    }

    /// A collision-free, bundle-id-safe slug identifying the target game — used to give each shortcut `.app`
    /// its OWN `CFBundleIdentifier`, so two games (or two shortcuts) never share one LaunchServices identity.
    var bundleIDComponent: String {
        switch self {
        case .playSteam(let appID): "steam-\(appID)"
        case .playManual(let id): "manual-\(id.uuidString.lowercased())"
        }
    }
}
