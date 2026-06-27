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

    /// Launch flags that keep the Steam client's CEF web helper from hanging/black-screening under
    /// Wine. `-no-cef-sandbox` is the key one: without it the CEF renderer goes "unresponsive" and
    /// Steam kills+relaunches it every ~90s forever, so the UI window never paints (verified). GPU is
    /// disabled (no accel under wine). `-cef-force-32bit` was dropped — Steam is 64-bit-CEF-only now
    /// and silently ignored it. Applied when opening Steam in the Master bottle.
    public static let steamLaunchArgs = ["-no-cef-sandbox", "-cef-disable-gpu", "-allosarches"]

    /// `WINEDLLOVERRIDES` used while creating/booting a prefix: disables wine-mono and wine-gecko so
    /// `wineboot` doesn't pop blocking "install Mono/Gecko?" dialogs and can complete headlessly.
    public static let winePrefixInitOverrides = "mscoree,mshtml="

    /// The single source of truth for a wine invocation's base environment: the isolated `WINEPREFIX`,
    /// quiet logging, and the bundled-dylib fallback path (so freetype/etc. resolve). Every wine launch
    /// builds on this and merges its own overrides, so a fix here (e.g. the DYLD path) reaches them all.
    public static func wineEnvironment(prefix: URL, wine: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all",
            "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback,
        ]
    }
}

extension URL {
    /// For a wine binary at `<root>/bin/wine[64]`, the bundled-dylib dir `<root>/lib/silo-bundled`
    /// (populated by Scripts/bundle-wine-dylibs.sh so the runtime carries its own freetype/gstreamer/…).
    public var siloBundledDylibDir: URL {
        deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/silo-bundled", isDirectory: true)
    }

    /// `DYLD_FALLBACK_LIBRARY_PATH` value so wine resolves missing deps. The bundle comes FIRST:
    /// empirically wine only finds its dlopen'd FreeType from the bundle, not from /usr/local/lib.
    /// (The glib/gstreamer double-load is avoided by NOT bundling that media stack — see
    /// Scripts/bundle-wine-dylibs.sh — rather than by reordering, which breaks fonts.)
    public var siloDyldFallback: String {
        "\(siloBundledDylibDir.path):/usr/local/lib:/usr/lib"
    }
}
