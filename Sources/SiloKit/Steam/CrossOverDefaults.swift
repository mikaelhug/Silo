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

// MARK: - Applications tab (per-app AppDefaults) — documented for a future parity phase, NOT yet implemented.
//
// CrossOver's winecfg → Applications tab lists exes with a per-app profile under
// `HKCU\Software\Wine\AppDefaults\<exe>`. From the Steam bottle's `user.reg`:
//
//   • cxcplinfo.exe   — CrossOver tool: enumerates installed Control Panel applets. (AppDefaults\…\Explorer)
//   • cxmklnk.exe     — CrossOver tool: creates `.lnk` shortcuts.                   (AppDefaults\…\Explorer)
//   • cxwget.exe      — CrossOver tool: GUI file downloader. Per-app DllOverride: `wininet=builtin`.
//   • winewrapper.exe — CrossOver's launcher half. Per-app DllOverrides: `crypt32=builtin`, `rsabase=builtin`,
//                       `rsaenh=builtin`.                                           (+ AppDefaults\…\Explorer)
//   • winemenubuilder.exe — UPSTREAM Wine (builds desktop/menu entries).            (AppDefaults\…\Explorer)
//
// Only `winemenubuilder.exe` exists in Silo's from-source Wine; `cxcplinfo`/`cxmklnk`/`cxwget`/`winewrapper`
// are CodeWeavers-proprietary binaries absent from Silo's runtime, so per-app profiles for them would be dead
// registry keys nothing consults. Full parity here would require Silo to ship equivalent helper binaries —
// a later phase. (cxbottle.conf's `WINEMSYNC=1` is already matched by Silo's launch env.)
