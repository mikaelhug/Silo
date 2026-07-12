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
///
/// This is the FIRST-hop scheme check. Silo's download security is layered, and the other two layers are
/// stronger than a per-hop scheme check would be, so this deliberately doesn't inspect redirect targets:
///  1. **Transport (per-hop cleartext):** ATS `NSAllowsArbitraryLoads=false` (Info.plist) makes the OS
///     refuse ANY cleartext connection at ANY hop — a redirect to `http://` fails the whole request, so a
///     downgrade can't happen even through a redirector (SourceForge, `aka.ms`).
///  2. **Content integrity:** every downloaded artifact that is then EXECUTED is verified against a pinned
///     SHA-256 before it runs — the Wine/DXMT runtime + app self-update (`RuntimeManager`/`Updater`), the
///     core-font `.exe`s and d3dcompiler cabs (`Silo.coreFontSHA256` / `Silo.d3dCompiler47…CabSHA256`,
///     checked in `SteamBottle`). That makes the serving host/mirror immaterial. (The Steam + VC-redist
///     *bootstrappers* auto-rotate versions, so they stay https+official-host without a content pin.)
enum DownloadGuard {
    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw DownloadError.insecureURL(url.scheme ?? "(none)")
        }
    }
}
