import Foundation

/// Persists the owned-games catalog to disk so the library shows **instantly** on launch instead of
/// re-running SteamCMD's slow (and cold-cache-flaky) enumeration every time. The catalog is refreshed
/// in the background and merged in, so it converges to the full set and games never disappear.
public actor LibraryCacheStore {
    private let url: URL

    public init(paths: AppPaths) {
        self.url = paths.supportDir.appendingPathComponent("library-cache.json")
    }

    public struct Cache: Codable, Sendable {
        public var username: String
        public var games: [SteamAppInfo]
        public var savedAt: Date
    }

    public func load() -> Cache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    public func save(username: String, games: [SteamAppInfo], at date: Date) {
        let cache = Cache(username: username, games: games, savedAt: date)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
