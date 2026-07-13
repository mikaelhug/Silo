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

    /// Repo whose releases host Silo's own Wine builds (the base D3DMetal runs on). Self-reliant by design:
    /// Silo compiles Wine from published open-source (LGPL) Wine sources in its own CI and hosts the result on
    /// its Releases, so it never depends on a third-party prebuilt that may go stale. See WINE-BUILD.md.
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
                                   "impact32", "times32", "trebuc32", "verdan32", "webdin32"]
    /// Winetricks' current corefonts mirror (its OWN primary download URL for these files) — byte-identical
    /// to SourceForge. SourceForge's `downloads.sourceforge.net` redirector is flaky, so each font falls back
    /// to this GitHub raw mirror when the primary download fails. Both mirrors are tamper-checked against the
    /// pinned SHA-256 below before the installer is executed, so which mirror served the bytes is immaterial.
    public static let coreFontsFallbackBaseURL = URL(string: "https://github.com/pushcx/corefonts/raw/master/")!
    /// Pinned SHA-256 of each core-font self-extracting `.exe` (keyed by `coreFonts` entry). Silo DOWNLOADS
    /// these from a third-party mirror and then EXECUTES them under Wine, so each is verified against its
    /// digest before it runs — a tampered/corrupt mirror is rejected, not executed. Values are winetricks'
    /// published pins (`src/winetricks`, the `load_corefonts` verb), cross-checked here against the live
    /// SourceForge + pushcx bytes (both matched, 2026-07-12). A completeness test asserts every `coreFonts`
    /// entry has one here.
    public static let coreFontSHA256: [String: String] = [
        "andale32": "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970",
        "arial32":  "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6",
        "arialb32": "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8",
        "comic32":  "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e",
        "courie32": "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384",
        "georgi32": "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301",
        "impact32": "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb",
        "times32":  "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab",
        "trebuc32": "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9",
        "verdan32": "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96",
        "webdin32": "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a",
    ]

    /// Adobe Source Han Sans — the open-source (SIL OFL 1.1) pan-CJK font family. Silo installs the four
    /// per-language "Language-specific OTF" packs (Japanese / Korean / Simplified / Traditional Chinese) into
    /// the Steam bottle so CJK games + Steam's UI render their glyphs. OFL is freely redistributable (no
    /// EULA), so these are downloaded, unzipped, and their `.otf` files copied into `windows/Fonts` (Wine
    /// registers dropped fonts automatically). ~90 MB each; pinned to the 2.004R release.
    public static let sourceHanSansBaseURL =
        URL(string: "https://github.com/adobe-fonts/source-han-sans/releases/download/2.004R/")!
    public static let sourceHanSansPacks = ["SourceHanSansJ", "SourceHanSansK", "SourceHanSansSC", "SourceHanSansTC"]

    /// Microsoft Visual C++ 2015–2022 Redistributable — the runtime many Steam games ship against. Installed
    /// **user-guided** (the bootstrapper shows a license the user must accept), x86 then x64, via Microsoft's
    /// permanent `aka.ms` URLs (they 302-redirect to `download.visualstudio.microsoft.com`; both https).
    public static let vcRedistX86URL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!
    public static let vcRedistX64URL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!

    /// `d3dcompiler_47.dll` (the HLSL shader compiler many D3D games need) — extracted from Microsoft's own
    /// Windows SDK cabinet files via Wine's builtin `expand` (no cabextract dependency), then set to a native
    /// DLL override. The member is a GUID-like filename inside each single-purpose cabinet (per winetricks).
    public static let d3dCompiler47X64CabURL = URL(string:
        "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/61d57a7a82309cd161a854a6f4619e52.cab")!
    public static let d3dCompiler47X64Member = "fil3585cb2ea5db13cc0838f8d06b5c9679"
    public static let d3dCompiler47X86CabURL = URL(string:
        "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/2630bae9681db6a9f6722366f47d055c.cab")!
    public static let d3dCompiler47X86Member = "fila319f706acfa16d6707473ebf29bdc7f"
    /// Pinned SHA-256 of the two d3dcompiler_47 SDK cabinets (keyed by their `…Member`), verified before the
    /// DLL is `wine expand`ed out and later loaded by games. These are fixed, GUID-named, immutable Microsoft
    /// SDK installers; winetricks itself doesn't pin them (it relies on cabextract matching a named member),
    /// so these are computed from Microsoft's own `download.microsoft.com` HTTPS artifacts (captured 2026-07-12,
    /// stable across re-download) — trust-on-first-use from the vendor, strictly stronger than the prior
    /// no-verification path.
    public static let d3dCompiler47X64CabSHA256 = "f736e161547095bb8d98c636b85fdfeb4070fefeee3c3745db3ce88f6eb1d9de"
    public static let d3dCompiler47X86CabSHA256 = "d0440eb81c532dc23639c0c63f2fcde9deddb23bb4cce01c19ac6b96cc3e269d"

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
    /// lives; EVERY wine invocation inside a bottle applies it — launches, provisioning (`wineboot`),
    /// installers, and font extraction alike — so a prefix only ever sees one wineserver flavor.
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
