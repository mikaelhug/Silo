import Foundation

/// A GitHub release as returned by `/repos/{owner}/{repo}/releases/latest`.
/// Decode with `keyDecodingStrategy = .convertFromSnakeCase`.
public struct GitHubRelease: Codable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let assets: [Asset]

    public struct Asset: Codable, Sendable, Equatable {
        public let name: String
        public let browserDownloadUrl: URL
    }

    /// Version with any leading `v` stripped (e.g. `v0.2.0` → `0.2.0`).
    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

extension URLRequest {
    /// A GitHub API request with the headers GitHub requires (it returns 403 with no User-Agent).
    static func github(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Silo/\(Silo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }
}
