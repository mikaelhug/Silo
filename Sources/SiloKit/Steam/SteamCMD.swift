import Foundation

/// Pure builders + metadata for driving Valve's headless **SteamCMD** client.
///
/// This is Silo's downloader after the pivot away from the Wine Steam GUI: native macOS SteamCMD
/// fetches the *Windows* depot of a game (`@sSteamCmdForcePlatformType windows`) with no Wine and no
/// CEF, so it can't hit the Steam-client black-window class of bugs. The downloaded files use the same
/// `appmanifest_*.acf` layout `DiscoveryEngine` already parses, and each game is then launched in its
/// own GPTK "bucket" (isolated prefix).
///
/// Everything here is a pure function (no I/O) so it unit-tests instantly; `SteamCMDClient` runs them.
public enum SteamCMD {
    /// Valve's official native macOS SteamCMD bootstrapper (self-updates on first run).
    public static let macInstallerURL =
        URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    /// Force SteamCMD to operate on Windows depots even though the host is macOS — the crux of the pivot.
    static let forcePlatformWindows = ["+@sSteamCmdForcePlatformType", "windows"]

    /// Arguments to download/update a game's **Windows** files into `installDir`, verifying integrity.
    /// Order matters: login → install dir → force platform → app_update (per SteamCMD's command stream).
    public static func downloadArguments(appID: Int, username: String, installDir: URL) -> [String] {
        ["+login", username,
         "+force_install_dir", installDir.path]
        + forcePlatformWindows
        + ["+app_update", String(appID), "validate", "+quit"]
    }

    /// Arguments to print a game's metadata (name, `oslist`/platforms, depots) — used to filter to
    /// Windows-only titles and to configure its bucket. Anonymous login is enough for public metadata.
    public static func appInfoArguments(appID: Int) -> [String] {
        ["+login", "anonymous"]
        + forcePlatformWindows
        + ["+app_info_update", "1", "+app_info_print", String(appID), "+quit"]
    }

    /// Arguments to list the licenses (owned packages) of a logged-in account.
    public static func licensesArguments(username: String) -> [String] {
        ["+login", username, "+licenses_print", "+quit"]
    }

    /// Arguments to print metadata for several packages in one session (→ their owned app IDs).
    public static func packageInfoArguments(username: String, packageIDs: [Int]) -> [String] {
        ["+login", username] + packageIDs.flatMap { ["+package_info_print", String($0)] } + ["+quit"]
    }

    /// Arguments to print metadata for several apps in one session (Windows view).
    public static func appInfoArguments(appIDs: [Int]) -> [String] {
        ["+login", "anonymous"] + forcePlatformWindows + ["+app_info_update", "1"]
        + appIDs.flatMap { ["+app_info_print", String($0)] } + ["+quit"]
    }

    // MARK: - Output parsing

    /// Package IDs from `licenses_print` output (lines like "License packageID 12345 :").
    public static func parseLicensePackageIDs(_ output: String) -> [Int] {
        var ids: [Int] = []
        for line in output.split(separator: "\n") {
            guard let r = line.range(of: "License packageID ") else { continue }
            let digits = line[r.upperBound...].prefix { $0.isNumber }
            if let id = Int(digits) { ids.append(id) }
        }
        return ids
    }

    /// App IDs granted by a package, from its `package_info_print` block (`appids { "0" "220" … }`).
    public static func parsePackageAppIDs(_ output: String, packageID: Int) -> [Int] {
        guard let block = SteamAppInfo.extractBlock(output, key: String(packageID)),
              let root = try? KeyValuesParser().parse(text: block),
              let appids = root[String(packageID)]?["appids"] else { return [] }
        return appids.pairs.compactMap { Int($0.value.stringValue ?? "") }
    }

    /// Arguments to establish a login session. First time, pass `password` (+ `guardCode` for Steam
    /// Guard); SteamCMD then caches a refresh token so later calls need only the username. Credentials
    /// go as args for a headless flow (brief `ps` visibility) — the cached token avoids re-entry.
    public static func loginArguments(username: String, password: String? = nil, guardCode: String? = nil) -> [String] {
        var login = ["+login", username]
        if let password { login.append(password) }
        if let guardCode { login.append(guardCode) }
        return login + ["+quit"]
    }
}
