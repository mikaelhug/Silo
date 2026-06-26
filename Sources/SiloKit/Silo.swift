import Foundation

/// Top-level namespace + build metadata for the Silo app.
public enum Silo {
    /// Marketing version. Kept in sync with `Info.plist` `CFBundleShortVersionString` by the build script.
    public static let version = "0.1.0"

    /// Stable bundle identifier (TCC prompts are keyed to this).
    public static let bundleID = "com.mikael.silo"

    /// User-facing product name.
    public static let appName = "Silo"

    /// GitHub repo (`owner/name`) the in-app updater checks for new app releases.
    public static let updateRepo = "mikaelhug/Silo"

    /// Repo whose releases host Silo's own CrossOver-based Wine builds (the base D3DMetal runs on).
    /// Self-reliant by design: built from CrossOver's open (LGPL) sources in our own CI and published
    /// to our Releases, so we never depend on a third-party prebuilt that may go stale. See WINE-BUILD.md.
    /// (Until the first build is published, the Wine tab is empty — install CrossOver, or override here.)
    public static let wineRepo = "mikaelhug/Silo"

    /// Apple's official GPTK page (manual DMG download, requires Apple ID).
    public static let appleGPTKURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    /// Official Steam Windows installer (silent flag `/S`).
    public static let steamInstallerURL =
        URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Launch flags that keep the Steam client's CEF web helper from black-screening/crashing under
    /// Wine (a well-known GPTK issue). Applied when opening Steam in the Master bottle.
    public static let steamLaunchArgs = ["-allosarches", "-cef-force-32bit", "-cef-disable-gpu"]
}
