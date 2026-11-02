import Foundation

/// Per-**process** Direct3D routing for the helper processes a game's launch spawns — the answer to
/// "the game needs GPTK, but its launcher needs a Direct3D 10.1 device D3DMetal cannot create" (issue #9).
///
/// **The gap.** D3DMetal implements no Direct3D 10 at all: GPTK's `d3d10.dll` `D3D10CreateDevice` and its
/// `dxgi.dll` `DXGID3D10CreateDevice` are both `puts(<signature>); return E_FAIL;` stubs (disassembled from
/// GPTK 4.0b2), so wine's `d3d10_1`/`d3d10core` — which create their device through the loaded `dxgi` —
/// fail with `0x80004005` under any GPTK launch. That takes Direct2D's hardware path down with it (wine's
/// `d2d1` sits on `D3D10CreateDevice1`), which is how the Rockstar Games Launcher draws its UI. And it can't
/// be fixed in-process: one process has exactly one `dxgi`, and the game needs D3DMetal's.
///
/// **The mechanism (verified on-device).** Every process in a launch inherits one environment AND one wine
/// runtime (`PlayGTAV.exe` → `Launcher.exe` → the game). Wine's only per-executable knob is the registry's
/// `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`, and `WINEDLLOVERRIDES` beats it — but only *name form
/// by name form*: wine looks a module up as the plain name first (env → AppDefaults → global), then as
/// `*name`. So when the launch env says `*dxgi=b` instead of `dxgi=b`, an AppDefaults `dxgi` entry for one
/// exe wins for that exe while `*dxgi=b` still governs every other process. Proven with a probe exe in a
/// scratch prefix on the GPTK runtime: under one launch environment, `Launcher.exe` (routed) created a
/// D3D10.1 device AND a hardware Direct2D HWND render target (`EndDraw` S_OK), while `Game.exe` (same
/// binary, not routed) kept D3DMetal's `dxgi`/`d3d11`/`d3d12` (`D3D11CreateDevice` → feature level 11_0).
///
/// **What a routed process gets.** The only D3D10-capable stack loadable inside the GPTK runtime (whose
/// `lib/wine` builtins ARE D3DMetal's) is **native DXVK** seeded into the prefix (`d3d10core`/`d3d11`/`dxgi`
/// `=native`, wine's builtin `d3d10_1` on top) — which also needs DXVK's patched MoltenVK on the DYLD path.
/// `d3d12`/`d3d12core` are **disabled** for it: D3DMetal's `d3d12` against a non-D3DMetal `dxgi` crashes
/// (the reporter hit 0xC0000005 exactly there with wined3d's dxgi), whereas a missing `d3d12.dll` is a case
/// every launcher already handles (Windows 7). The NVIDIA shims are disabled likewise (they are D3DMetal's).
///
/// **Scope.** Only GPTK needs this (`GraphicsBackend.supportsD3D10`): DXMT and DXVK implement D3D10 natively,
/// and their launches keep the PLAIN override form, so these AppDefaults entries are inert there. The
/// entries are keyed by executable BASENAME (wine's AppDefaults has no path form) and they live in the
/// prefix, so they're written only once the helper is actually installed in that prefix — the launcher a
/// Rockstar stub installs on first run is therefore routed from the following launch on.
public enum ProcessRouting {
    /// A helper executable that needs Direct3D 10.x and is spawned inside a game's launch.
    public struct Helper: Sendable, Hashable {
        /// The executable's basename — what wine keys `AppDefaults` on.
        public let executable: String
        /// `drive_c`-relative locations; the helper counts as installed when any one exists.
        public let installPaths: [String]
    }

    /// The known D3D10-dependent helpers. Add an entry here (with the evidence) to route another one.
    /// - Rockstar Games Launcher: draws its UI with Direct2D on a D3D10.1 device; issue #9's relay trace
    ///   shows `D3D10CreateDevice1` → `DXGID3D10CreateDevice` → `0x80004005` under GPTK, then its fatal
    ///   "failed to initialize" dialog. Every Rockstar title on Steam starts through it.
    public static let d3d10Helpers: [Helper] = [
        Helper(executable: "Launcher.exe", installPaths: [
            "Program Files/Rockstar Games/Launcher/Launcher.exe",
            "Program Files (x86)/Rockstar Games/Launcher/Launcher.exe",
        ]),
    ]

    /// The per-module load order a routed helper gets, in its `AppDefaults\<exe>\DllOverrides` key.
    /// `""` = disabled (wine's spelling in the registry).
    public static let helperOverrides: [(module: String, mode: String)] = [
        ("d3d10core", "native"), ("d3d11", "native"), ("dxgi", "native"),   // DXVK, seeded into the prefix
        ("d3d10_1", "builtin"),                                               // wine's, on top of DXVK's d3d10core
        ("d3d12", ""), ("d3d12core", ""),                                     // D3DMetal's d3d12 needs its dxgi
        ("nvapi64", ""), ("nvngx", ""),                                       // D3DMetal's NVIDIA shims, likewise
    ]

    /// The modules routing claims per executable — exactly the ones the launch env must emit in `*module`
    /// form for the AppDefaults entries to take effect (`DllOverrideList.wildcarding`).
    public static var routedModules: Set<String> {
        Set(helperOverrides.map { DllOverrideList.key(for: $0.module) })
    }

    /// The helpers installed in `prefix`. File-existence checks only — cheap, called once per launch.
    public static func installedHelpers(in prefix: URL, fileManager: FileManager = .default) -> [Helper] {
        let driveC = prefix.appendingPathComponent("drive_c")
        return d3d10Helpers.filter { helper in
            helper.installPaths.contains { fileManager.fileExists(atPath: driveC.appendingPathComponent($0).path) }
        }
    }

    /// The `regedit` script that writes every helper's `AppDefaults` entry. REGEDIT4 (ANSI), CRLF — the same
    /// shape `SteamBottle.applyWineDefaults` imports; names contain no characters that need escaping.
    public static func registryScript(for helpers: [Helper]) -> String {
        var reg = "REGEDIT4\r\n"
        for helper in helpers {
            reg += "\r\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(helper.executable)\\DllOverrides]\r\n"
            for (module, mode) in helperOverrides { reg += "\"\(module)\"=\"\(mode)\"\r\n" }
        }
        return reg
    }

    /// Whether `userReg` (the prefix's `user.reg` text) already carries every helper's full routing entry —
    /// so a launch only runs `regedit` when something is missing (self-healing if the key is ever removed).
    /// Wine writes the key as `[Software\\Wine\\AppDefaults\\<exe>\\DllOverrides] <timestamp>`.
    public static func isApplied(for helpers: [Helper], userReg: String) -> Bool {
        let lines = userReg.components(separatedBy: .newlines)
        return helpers.allSatisfy { helper in
            let header = "[software\\\\wine\\\\appdefaults\\\\\(helper.executable.lowercased())\\\\dlloverrides]"
            guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix(header) }) else { return false }
            var values: Set<String> = []
            for line in lines[(start + 1)...] {
                if line.hasPrefix("[") { break }
                values.insert(line.trimmingCharacters(in: .whitespaces).lowercased())
            }
            return helperOverrides.allSatisfy { values.contains("\"\($0.module)\"=\"\($0.mode)\"") }
        }
    }
}
