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

    /// Official Windows Steam installer (run with `/S` for a silent install into the Steam bottle).
    public static let steamInstallerURL =
        URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// `WINEDLLOVERRIDES` used while creating/booting a prefix: disables wine-mono and wine-gecko so
    /// `wineboot` doesn't pop blocking "install Mono/Gecko?" dialogs and can complete headlessly.
    public static let winePrefixInitOverrides = "mscoree,mshtml="

    /// `WINEDLLOVERRIDES` fragment disabling Wine drivers that crash the whole Wine process on macOS.
    /// `winebus.sys` (the HID/game-controller bus) `dlopen`s libSDL2 on a Wine worker thread; SDL's macOS
    /// initializer pops an `NSAlert` off the main thread → "NSWindow should only be instantiated on the
    /// main thread" → the process aborts before Steam (or a game) ever draws. `winexinput.sys` rides on the
    /// same path. Disabling them costs in-Wine controller support but lets Steam/games actually launch.
    /// The trailing `=` is the DISABLED disposition (like `mscoree,mshtml=`); `=d` is NOT valid Wine syntax
    /// (only `n`/`b`/empty) and silently leaves the driver enabled.
    public static let crashyDriverOverrides = "winebus,winexinput="

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

    /// `DYLD_FALLBACK_LIBRARY_PATH` value so wine resolves missing deps. ONLY the self-contained bundle +
    /// system `/usr/lib` — deliberately NOT `/usr/local/lib` (x86_64 Homebrew). With Homebrew on the
    /// fallback path, winegstreamer dlopen'd Homebrew's gtk3 AND gtk4, triggering "Class … is implemented
    /// in both" ObjC duplicate-registration crashes (seen launching Steam in the bottle). The bundle
    /// carries wine's real deps (freetype etc.), so dropping /usr/local/lib keeps the runtime hermetic.
    public var siloDyldFallback: String {
        "\(siloBundledDylibDir.path):/usr/lib"
    }
}
