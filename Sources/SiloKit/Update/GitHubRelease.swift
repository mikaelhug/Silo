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
        public let size: Int
    }

    /// Version with any leading `v` stripped (e.g. `v0.2.0` → `0.2.0`).
    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}
