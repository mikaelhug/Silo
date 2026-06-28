import Foundation

/// Errors for the pre-flight check applied to every release-derived download URL.
public enum DownloadError: Error, Sendable, Equatable {
    /// The URL's scheme is not `https` (rejects `http`/`file`/data/other before any network call).
    case insecureURL(String)
}

/// Pre-flight guard for URLs that come (directly or indirectly) from a remote source — GitHub release
/// assets, the user-overridable wine repo, the Steam installer CDN. We require **https** so the app
/// can't be tricked into a cleartext download (downgrade/MITM) or a `file:`-scheme local read.
///
/// Deliberately NOT host-pinned: the wine repo is user-overridable and the Steam installer lives on a
/// steamstatic CDN, so https-only is the right bar. Call before every `session.download`/`session.data`
/// on such a URL.
enum DownloadGuard {
    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw DownloadError.insecureURL(url.scheme ?? "(none)")
        }
    }
}
