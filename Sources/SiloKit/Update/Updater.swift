import Foundation

/// Checks GitHub Releases for a newer app build. Dependency-free (no Sparkle): just `URLSession`.
public struct Updater: Sendable {
    private let repo: String
    private let currentVersion: String
    private let session: URLSession

    public init(repo: String = Silo.updateRepo, currentVersion: String = Silo.version, session: URLSession = .shared) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.session = session
    }

    public enum UpdateError: Error, Sendable, Equatable {
        case badResponse(Int)
    }

    public struct UpdateCheck: Sendable, Equatable {
        public let latestVersion: String
        public let isNewer: Bool
        public let downloadURL: URL?
        public let releaseName: String?
    }

    public func checkForUpdate() async throws -> UpdateCheck {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let asset = release.assets.first { $0.name.hasSuffix(".zip") }
        return UpdateCheck(
            latestVersion: release.version,
            isNewer: Self.isVersion(release.version, newerThan: currentVersion),
            downloadURL: asset?.browserDownloadUrl,
            releaseName: release.name
        )
    }

    /// Numeric, component-aware version comparison (`0.10.0` > `0.9.0`).
    static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        candidate.compare(baseline, options: .numeric) == .orderedDescending
    }
}
