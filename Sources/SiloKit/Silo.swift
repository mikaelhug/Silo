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

    /// Microsoft's redistributable "Core fonts for the Web" (the winetricks `corefonts` set), from
    /// SourceForge's canonical mirror. Installed into each Steam bottle during setup — Wine ships no
    /// TrueType MS fonts, so Steam's UI and many games render with wrong/blank glyphs without these. Each
    /// is a self-extracting installer whose `.ttf` Silo extracts via Wine's own IExpress `/T /C /Q`
    /// (no cabextract / winetricks dependency). Redistribution complies with the EULA — we download and
    /// run Microsoft's original installers, never re-host the fonts.
    public static let coreFontsBaseURL = URL(string: "https://downloads.sourceforge.net/corefonts/")!
    public static let coreFonts = ["andale32", "arial32", "arialb32", "comic32", "courie32", "georgi32",
                                   "impact32", "times32", "trebuc32", "verdan32", "webdings32"]

    /// `WINEDLLOVERRIDES` used while creating/booting a prefix: disables wine-mono and wine-gecko so
    /// `wineboot` doesn't pop blocking "install Mono/Gecko?" dialogs and can complete headlessly.
    /// (The winebus/SDL crash is NOT fixed here — `WINEDLLOVERRIDES` can't disable a PnP `.sys` driver;
    /// the fix is removing libSDL2 from the runtime: build `--without-sdl` + `RuntimeManager.stripBundledSDL`.)
    public static let winePrefixInitOverrides = "mscoree,mshtml="

    /// `WINEDEBUG` for every wine invocation. **LOCAL builds: `+loaddll` — wine's default diagnostics
    /// (err/warn/fixme) PLUS module-load tracing, so launch logs are useful while developing.
    /// CI/distribution builds: `-all,+winediag` — quiet EXCEPT wine's `winediag` channel, which carries the
    /// graphics-fallback signatures (`Using the Vulkan renderer`, `None of the requested D3D feature levels`)
    /// that the `GraphicsFallback` guardrail keys on. A plain `-all` would hide them and leave the guardrail
    /// blind in the shipped app.** Gated on the `SILO_QUIET_WINE` compile flag, which `Scripts/build-app.sh`
    /// sets only when `$CI` is present, so the shipped app is quiet automatically (no manual flip).
    public static let wineDebug: String = {
        #if SILO_QUIET_WINE
        return "-all,+winediag"
        #else
        return "+loaddll"
        #endif
    }()

    /// The single source of truth for a wine invocation's base environment: the isolated `WINEPREFIX`,
    /// logging (see `wineDebug`), and the bundled-dylib fallback path (so freetype/etc. resolve). Every wine
    /// launch builds on this and merges its own overrides, so a fix here (e.g. the DYLD path) reaches them all.
    public static func wineEnvironment(prefix: URL, wine: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": wineDebug,
            "DYLD_FALLBACK_LIBRARY_PATH": wine.siloDyldFallback,
        ]
    }

    /// Enforce the co-residency sync rule on a wine environment: `WINEMSYNC=1`, any `WINEESYNC` removed.
    /// Wine starts a SEPARATE wineserver per (prefix, sync-mode), and everything Silo runs in a bottle —
    /// the Steam client, the games co-resident with it, `taskkill`, registry edits, maintenance tools —
    /// must attach to the SAME wineserver: a mismatched sync mode silently forks a second server, which
    /// breaks Steamworks IPC (games) or aims a tool at the wrong server. This is the ONE place the rule
    /// lives; every bottle-sharing launch path applies it.
    public static func enforceMsync(_ env: inout [String: String]) {
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = nil
    }

    /// `wineEnvironment` + `enforceMsync` — the base env for anything Silo runs inside a bottle that must
    /// share that bottle's wineserver.
    public static func msyncWineEnvironment(prefix: URL, wine: URL) -> [String: String] {
        var env = wineEnvironment(prefix: prefix, wine: wine)
        enforceMsync(&env)
        return env
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
