import Foundation

/// Seeds a logged-in session into a Wine Steam install by copying the login-bearing files from the
/// **native macOS Steam** client's data dir. This is how a game's prefix gets an authenticated Steam
/// **without a second login** (and without the CEF login window rendering): the user signs into macOS
/// Steam once, Silo copies that session into the bottle.
///
/// Verified community-reported method (Whisky #41): copying `config/`, `registry.vdf`, the `ssfn*` sentry
/// files, and `userdata/` from `~/Library/Application Support/Steam` into the Wine prefix's Steam dir
/// produces a logged-in client. Pure file I/O — no process execution — so it unit-tests directly.
public struct SteamLoginSeeder: Sendable {
    public init() {}
    private var fileManager: FileManager { .default }

    /// Fixed login-bearing items (the `ssfn*` sentry files are matched by prefix at copy time, since
    /// they're named per-account). Kept as a constant so the exact set is easy to tune during validation.
    static let loginItems = ["config", "registry.vdf", "userdata"]
    static let sentryPrefix = "ssfn"

    public enum SeedError: Error, Sendable, Equatable {
        case macSteamNotFound(URL)
        case notLoggedIn   // macOS Steam exists but has no cached login to copy
    }

    /// Copy the login state from `macSteam` into `bottleSteam` (replacing any existing copies). Returns
    /// the item names actually copied. Throws if macOS Steam isn't present or has never logged in.
    @discardableResult
    public func seed(from macSteam: URL, into bottleSteam: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: macSteam.path) else { throw SeedError.macSteamNotFound(macSteam) }
        // loginusers.vdf inside config/ is what actually carries the remembered account + refresh token.
        let loginUsers = macSteam.appendingPathComponent("config/loginusers.vdf")
        guard fileManager.fileExists(atPath: loginUsers.path) else { throw SeedError.notLoggedIn }

        try fileManager.createDirectory(at: bottleSteam, withIntermediateDirectories: true)
        var names = Self.loginItems
        names += (try? fileManager.contentsOfDirectory(atPath: macSteam.path))?
            .filter { $0.hasPrefix(Self.sentryPrefix) } ?? []

        var copied: [String] = []
        for name in names {
            let src = macSteam.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: src.path) else { continue }
            let dest = bottleSteam.appendingPathComponent(name)
            if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
            try fileManager.copyItem(at: src, to: dest)
            copied.append(name)
        }
        return copied
    }
}
