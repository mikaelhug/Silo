import Foundation

/// Silo's default Wine registry configuration for the Steam bottle.
///
/// A bare `wineboot --init` prefix starts with an essentially EMPTY `HKCU\Software\Wine\DllOverrides` —
/// modern Wine keeps its DLL-selection policy in the loader's built-in defaults. To behave like a real
/// Windows install for the widest range of games, Silo seeds the bottle with the standard
/// Windows-compatibility override set (the classic Wine default template).
extension Silo {
    /// Silo's default `[Software\Wine\DllOverrides]` set for the Steam bottle — the standard
    /// Windows-compatibility overrides a bare `wineboot` prefix omits (the DirectPlay/quartz/riched/mshtml/
    /// crypt/COM families, etc.). Applied by `SteamBottle.applyWineDefaults`. `*`-prefixed names are wildcard
    /// app/exe overrides; the rest are DLLs. Mode `""` = disabled; `native,builtin` = prefer a native file if
    /// one is present, else the builtin; `builtin` = force the builtin.
    ///
    /// NB: the runtime DLLs Silo installs as native files (d3dcompiler_47, msvcp140, vcruntime140) are
    /// deliberately NOT listed — Wine's builtins drive them at runtime; the redist is installed only so games'
    /// dependency checks pass (see `installVCRedist` / `installD3DCompiler47`). Pinned by a unit test
    /// (`defaultDllOverridesAreComplete`).
    public static let defaultDllOverrides: [(name: String, mode: String)] = [
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
