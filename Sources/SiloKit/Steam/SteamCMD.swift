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
}
