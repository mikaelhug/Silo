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

    /// Default third-party repo (`owner/name`) for downloadable Wine/GPTK runtimes.
    /// `Gcenx/game-porting-toolkit` publishes prebuilt GPTK binaries (no Apple-ID login needed).
    /// Overridable in Settings.
    public static let defaultRuntimeRepo = "Gcenx/game-porting-toolkit"

    /// Repo for one-click GPTK fetches. Apple's official `apple/game-porting-toolkit` has no binary
    /// releases (DMG is behind Apple-ID login); Gcenx republishes prebuilt binaries.
    public static let gptkRepo = "Gcenx/game-porting-toolkit"

    /// Apple's official GPTK page (manual DMG download, requires Apple ID).
    public static let appleGPTKURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    /// Official Steam Windows installer (silent flag `/S`).
    public static let steamInstallerURL =
        URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
}
