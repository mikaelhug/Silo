import Foundation

/// Top-level namespace + build metadata for the Silo app. Version numbers live in `versions.env` (the
/// single source of truth) and reach the code via the generated `Versions` enum — see `Scripts/gen-versions.sh`.
public enum Silo {
    /// Marketing version. Kept in sync with `Info.plist` `CFBundleShortVersionString` by the build script.
    public static let version = Versions.silo

    /// Stable bundle identifier (TCC prompts are keyed to this).
    public static let bundleID = "com.mikael.silo"

    /// User-facing product name.
    public static let appName = "Silo"

    /// GitHub repo (`owner/name`) the in-app updater checks for new app releases.
    public static let updateRepo = Versions.githubRepo

    /// Repo whose releases host Silo's own CrossOver-based Wine builds (the base D3DMetal runs on).
    /// Self-reliant by design: built from CrossOver's open (LGPL) sources in our own CI and published
    /// to our Releases, so we never depend on a third-party prebuilt that may go stale. See WINE-BUILD.md.
    /// (Until the first build is published, the Wine tab is empty — install CrossOver, or override here.)
    public static let wineRepo = Versions.githubRepo

    /// Apple's official GPTK page (manual DMG download, requires Apple ID).
    public static let appleGPTKURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    /// Official Windows Steam installer (run with `/S` for a silent install into the Steam bottle).
    public static let steamInstallerURL =
        URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// `WINEDLLOVERRIDES` used while creating/booting a prefix: disables wine-mono and wine-gecko so
    /// `wineboot` doesn't pop blocking "install Mono/Gecko?" dialogs and can complete headlessly.
    /// (The winebus/SDL crash is NOT fixed here — `WINEDLLOVERRIDES` can't disable a PnP `.sys` driver;
    /// the fix is removing libSDL2 from the runtime: build `--without-sdl` + `RuntimeManager.stripBundledSDL`.)
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
        WineRuntimeLayout(wineBinary: self).bundledDylibDir
    }

    /// `DYLD_FALLBACK_LIBRARY_PATH` value so wine resolves missing deps. ONLY the self-contained bundle +
    /// system `/usr/lib` — deliberately NOT `/usr/local/lib` (x86_64 Homebrew). With Homebrew on the
    /// fallback path, winegstreamer dlopen'd Homebrew's gtk3 AND gtk4, triggering "Class … is implemented
    /// in both" ObjC duplicate-registration crashes (seen launching Steam in the bottle). The bundle
    /// carries wine's real deps (freetype etc.), so dropping /usr/local/lib keeps the runtime hermetic.
    public var siloDyldFallback: String {
        "\(siloBundledDylibDir.path):/usr/lib"
    }

    /// For a wine binary at `<root>/bin/wine[64]`, the runtime's `lib/external` dir, where Silo overlays
    /// GPTK's `libd3dshared.dylib` + `D3DMetal.framework` (see `GraphicsLinker.overlayGPTK`). GPTK's unix
    /// `.so` modules symlink here (`../../external/libd3dshared.dylib`) and the GPTK launch DYLD fallbacks
    /// point here, so the runtime is self-contained for D3DMetal once overlaid.
    public var wineRuntimeExternalDir: URL {
        WineRuntimeLayout(wineBinary: self).externalDir
    }
}
