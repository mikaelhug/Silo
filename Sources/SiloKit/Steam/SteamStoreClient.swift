import Foundation

/// Rich, public Steam-store metadata for a game's detail view (description, developer, genres, art).
/// Fetched on demand (only when a detail view opens — keeps within the store API's rate limits).
public struct SteamStoreDetails: Sendable, Equatable {
    public let appID: Int
    public let shortDescription: String?
    public let developers: [String]
    public let publishers: [String]
    public let genres: [String]
    public let headerImageURL: URL?
    public let releaseDate: String?
}

/// Fetches `SteamStoreDetails` from the public `store.steampowered.com/api/appdetails` endpoint
/// (no key required). One app per request.
public struct SteamStoreClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func details(appID: Int) async -> SteamStoreDetails? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        return Self.parse(data, appID: appID)
    }

    /// Parse the `{ "<appid>": { "success": true, "data": { … } } }` response.
    static func parse(_ data: Data, appID: Int) -> SteamStoreDetails? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[String(appID)] as? [String: Any],
              entry["success"] as? Bool == true,
              let d = entry["data"] as? [String: Any] else { return nil }
        let genres = (d["genres"] as? [[String: Any]])?.compactMap { $0["description"] as? String } ?? []
        return SteamStoreDetails(
            appID: appID,
            shortDescription: (d["short_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            developers: d["developers"] as? [String] ?? [],
            publishers: d["publishers"] as? [String] ?? [],
            genres: genres,
            headerImageURL: (d["header_image"] as? String).flatMap { URL(string: $0) },
            releaseDate: (d["release_date"] as? [String: Any])?["date"] as? String)
    }
}
