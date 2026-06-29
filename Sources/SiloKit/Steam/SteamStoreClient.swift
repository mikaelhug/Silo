import Foundation

/// Rich, public Steam-store metadata for a game's detail view (description, developer, genres, art,
/// minimum system requirements incl. disk space, Metacritic, capabilities).
/// Fetched on demand (only when a detail view opens — keeps within the store API's rate limits).
public struct SteamStoreDetails: Sendable, Equatable {
    public let appID: Int
    public let shortDescription: String?
    public let developers: [String]
    public let publishers: [String]
    public let genres: [String]
    public let headerImageURL: URL?
    public let releaseDate: String?
    /// Minimum PC requirements as readable text (the source of disk-size info before install).
    public let minimumRequirements: String?
    /// The storage line pulled out of the minimum requirements, e.g. "50 GB available space".
    public let diskSpace: String?
    /// Metacritic score (0–100), when the store provides one.
    public let metacritic: Int?
}

/// Fetches `SteamStoreDetails` from the public `store.steampowered.com/api/appdetails` endpoint
/// (no key required). One app per request.
public struct SteamStoreClient: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func details(appID: Int) async -> SteamStoreDetails? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english"),
              (try? DownloadGuard.requireHTTPS(url)) != nil,   // https-only, consistent with every other fetch
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
        // `pc_requirements` is a dict when present, or an empty array when the store lists none.
        let minRaw = (d["pc_requirements"] as? [String: Any])?["minimum"] as? String
        let minText = minRaw.map(stripHTML).flatMap { $0.isEmpty ? nil : $0 }
        return SteamStoreDetails(
            appID: appID,
            shortDescription: (d["short_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            developers: d["developers"] as? [String] ?? [],
            publishers: d["publishers"] as? [String] ?? [],
            genres: genres,
            headerImageURL: (d["header_image"] as? String).flatMap { URL(string: $0) },
            releaseDate: (d["release_date"] as? [String: Any])?["date"] as? String,
            minimumRequirements: minText,
            diskSpace: minText.flatMap(diskSpace),
            metacritic: (d["metacritic"] as? [String: Any])?["score"] as? Int)
    }

    /// Pull the storage requirement out of the minimum-requirements text (the disk-size signal).
    static func diskSpace(in requirements: String) -> String? {
        guard let line = requirements.split(separator: "\n").first(where: {
            let l = $0.lowercased()
            return l.contains("storage") || l.contains("hard drive") || l.contains("available space")
        }) else { return nil }
        let value = line.firstIndex(of: ":").map { String(line[line.index(after: $0)...]) } ?? String(line)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convert Steam's requirements HTML (`<ul><li><strong>OS:</strong> …`) into readable lines.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for tag in ["<br>", "<br/>", "<br />", "</li>", "</p>", "</ul>"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        var lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.first?.lowercased() == "minimum:" { lines.removeFirst() }   // redundant with the section header
        return lines.joined(separator: "\n")
    }
}
