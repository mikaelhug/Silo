import Foundation

/// CrossOver-parity configuration for the Steam bottle's Wine registry.
///
/// A vanilla `wineboot --init` prefix (what Silo creates) starts with an essentially EMPTY
/// `HKCU\Software\Wine\DllOverrides` — upstream Wine moved DLL-selection policy into the loader's built-in
/// defaults. CrossOver, by contrast, seeds every bottle from a template whose `system.reg`/`user.reg` carries
/// the classic Wine default-override list. Since Silo runs the **same CrossOver-FOSS Wine build**, applying
/// the same overrides reproduces CrossOver's bottle behaviour for games.
extension Silo {
    /// The exact `[Software\Wine\DllOverrides]` set read from a CrossOver Steam bottle's `user.reg`
    /// (`~/Library/Application Support/CrossOver/Bottles/Steam`), in CrossOver's order. Applied to Silo's
    /// Steam bottle by `SteamBottle.applyWineDefaults`. `*`-prefixed names are wildcard app/exe overrides;
    /// the rest are DLLs. Mode `""` = disabled. Whitespace is normalized (`native,builtin`; Wine trims). A
    /// few entries are legacy/no-op names with no modern Wine builtin (`*docbox.api`, `*ieinfo5.ocx`,
    /// `*maildoff.exe`, `*autorun.exe`, `iernonce`) — harmless wildcards, kept verbatim for exact parity.
    ///
    /// The list is pinned by a parity unit test (`crossOverOverridesParity`); a change here must be a
    /// deliberate, mirrored edit there.
    public static let crossOverDllOverrides: [(name: String, mode: String)] = [
        ("*autorun.exe", "native,builtin"),
        ("*ctfmon.exe", "builtin"),
        ("*ddhelp.exe", "builtin"),
        ("*docbox.api", ""),
        ("*findfast.exe", "builtin"),
        ("*ieinfo5.ocx", "builtin"),
        ("*maildoff.exe", "builtin"),
        ("*mdm.exe", "builtin"),
        ("*mosearch.exe", "builtin"),
        ("*msiexec.exe", "builtin"),
        ("*pstores.exe", "builtin"),
        ("*user.exe", "native,builtin"),
        ("amstream", "native,builtin"),
        ("atl", "native,builtin"),
        ("crypt32", "native,builtin"),
        ("d3dxof", "native,builtin"),
        ("dciman32", "native"),
        ("devenum", "native,builtin"),
        ("dplay", "native,builtin"),
        ("dplaysvr.exe", "native,builtin"),
        ("dplayx", "native,builtin"),
        ("dpnaddr", "native,builtin"),
        ("dpnet", "native,builtin"),
        ("dpnhpast", "native,builtin"),
        ("dpnhupnp", "native,builtin"),
        ("dpnlobby", "native,builtin"),
        ("dpnsvr.exe", "native,builtin"),
        ("dpnwsock", "native,builtin"),
        ("dxdiagn", "native,builtin"),
        ("hhctrl.ocx", "native,builtin"),
        ("hlink", "native,builtin"),
        ("iernonce", "native,builtin"),
        ("itss", "native,builtin"),
        ("jscript", "native,builtin"),
        ("mlang", "native,builtin"),
        ("mshtml", "native,builtin"),
        ("msi", "builtin"),
        ("msvcirt", "native,builtin"),
        ("msvcrt40", "native,builtin"),
        ("msvcrtd", "native,builtin"),
        ("odbc32", "native,builtin"),
        ("odbccp32", "native,builtin"),
        ("ole32", "builtin"),
        ("oleaut32", "builtin"),
        ("olepro32", "builtin"),
        ("quartz", "native,builtin"),
        ("riched20", "native,builtin"),
        ("riched32", "native,builtin"),
        ("rpcrt4", "builtin"),
        ("rsabase", "native,builtin"),
        ("secur32", "native,builtin"),
        ("shdoclc", "native,builtin"),
        ("shdocvw", "native,builtin"),
        ("softpub", "native,builtin"),
        ("urlmon", "native,builtin"),
        ("wininet", "builtin"),
        ("wintrust", "native,builtin"),
        ("wscript.exe", "native,builtin"),
    ]
}

// MARK: - Applications tab (per-app AppDefaults) — investigated 2026-07-10; INTENTIONALLY not replicated.
//
// CrossOver's winecfg → Applications tab lists five exes — each a REAL compiled binary present in the bottle's
// `system32`/`syswow64` — with a tiny per-app profile under `HKCU\Software\Wine\AppDefaults\<exe>`:
//
//   • winewrapper.exe (204 KB)     — CrossOver's app-launcher core (its `wine` command = a Perl script + this
//                                    binary). Profile: DllOverrides crypt32/rsabase/rsaenh=builtin; Desktop=root.
//   • cxwget.exe      (52 KB)      — CrossOver's GUI downloader (fetches fonts/redists during its bottle setup).
//                                    Profile: DllOverrides wininet=builtin; Desktop=root.
//   • cxmklnk.exe     (56 KB)      — CrossOver's `.lnk` handler: records Windows Start-Menu shortcuts so
//                                    CrossOver can mirror them into macOS menus. Profile: Desktop=root.
//   • cxcplinfo.exe   (48 KB)      — CrossOver's Control-Panel-applet enumerator (for its UI). Desktop=root.
//   • winemenubuilder.exe (138 KB) — UPSTREAM Wine: turns Windows shortcuts + file associations into macOS
//                                    menu entries. Profile: Desktop=root. (`Desktop=root` = run rootless.)
//
// Why they are NOT replicated (decided 2026-07-10): the first four are CodeWeavers-PROPRIETARY product plumbing
// (launcher / downloader / menu integration / control-panel browser) — closed-source, absent from Silo's
// CrossOver-FOSS Wine, and depended on by NO game. Silo already does each job natively (URLSession downloads,
// `LaunchOrchestrator` launches, its own library UI). There are ZERO game-specific per-app profiles on this
// tab, so nothing here affects game behavior. `winemenubuilder.exe` is the only upstream component (Silo's Wine
// already has it); CrossOver keeps it ENABLED as a feature (installed Windows apps appear in the macOS menu) —
// for a game launcher you'd sooner want the opposite (disable it so games don't create stray menu entries / grab
// file associations), a deliberate DIVERGENCE from CrossOver, not parity. (`cxbottle.conf` `WINEMSYNC=1` is
// already matched by Silo's launch env.)
