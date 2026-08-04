import Foundation

/// Which Direct3D APIs a game actually uses — the **single** signal every backend decision is made from
/// (`BackendChooser.choose`, `dxmtMightHelp`, `dxvkMightHelp`), so the forward choice and the reactive
/// GPTK → DXMT → DXVK ladder can never disagree about what the game needs.
///
/// Derived by unioning the PE imports of the game's executable **and the DLLs shipped beside it**
/// (`scan(executable:)`). Scanning only the `.exe` — as Silo did before — misses most real titles, because
/// the renderer usually lives in a DLL: Source games import `d3d9` from `bin/shaderapidx9.dll`, Unity from
/// `UnityPlayer.dll`, and UE from its `Binaries/Win64` DLLs, while the `.exe` is a thin stub.
public struct D3DProfile: Sendable, Equatable {
    /// The game references `d3d8` — **no Silo backend translates it** (DXVK ships no d3d8, and wine's builtin
    /// `d3d8` sits directly on wined3d rather than forwarding through `d3d9`). wined3d IS the right answer
    /// here, so a DX8 title must not be dragged through the reroute ladder.
    public var usesD3D8 = false
    /// The game references `d3d9` (the only API DXVK alone can translate — GPTK/DXMT have no d3d9).
    public var usesD3D9 = false
    /// The game references D3D10/10.1/11 — translatable by all three backends.
    public var usesD3D1x = false
    /// The game references D3D12 — **GPTK only**; neither DXMT nor DXVK implements it.
    public var usesD3D12 = false
    /// The game references `opengl32` — Wine's OpenGL, which goes straight to macOS's GL. **No Silo backend
    /// touches this**: GPTK, DXMT and DXVK all translate Direct3D. Worth knowing so we never tell the user to
    /// "switch backend" for a game no backend can affect.
    public var usesOpenGL = false
    /// The game calls **Vulkan directly** (`vulkan-1.dll`). No D3D translation is needed, but it still needs a
    /// working Vulkan driver — and only the DXVK runtime ships one that works (see `isVulkanNative`).
    public var usesVulkan = false

    public init(usesD3D8: Bool = false, usesD3D9: Bool = false, usesD3D1x: Bool = false,
                usesD3D12: Bool = false, usesVulkan: Bool = false, usesOpenGL: Bool = false) {
        self.usesOpenGL = usesOpenGL
        self.usesD3D8 = usesD3D8
        self.usesD3D9 = usesD3D9
        self.usesD3D1x = usesD3D1x
        self.usesD3D12 = usesD3D12
        self.usesVulkan = usesVulkan
    }

    /// No Direct3D reference found anywhere. Means **unknown**, NOT "no Direct3D": a game can load D3D
    /// dynamically via `LoadLibrary`, or hide it behind a packed/protected binary. Every consumer treats
    /// this as "don't rule anything out" (fail-open), except the DX9-first route which needs positive proof.
    public var isUnknown: Bool {
        !usesD3D8 && !usesD3D9 && !usesD3D1x && !usesD3D12 && !usesVulkan && !usesOpenGL
    }

    /// An OpenGL game with no Direct3D at all. Runs on Wine's own GL → macOS OpenGL, which Apple caps at the
    /// 2.1 compatibility profile (only 3.2+ *core* exists), so a title demanding GL 3.0 compat cannot be
    /// satisfied — and **no graphics backend changes that**, since all three translate Direct3D.
    public var isOpenGLOnly: Bool {
        usesOpenGL && !usesD3D8 && !usesD3D9 && !usesD3D1x && !usesD3D12 && !usesVulkan
    }

    /// A pure DirectX 9 title — the one case **only DXVK** can drive (GPTK doesn't translate DX9 at all and
    /// DXMT is D3D10/11-only, so this game would otherwise fall to wined3d and usually black-screen).
    /// Deliberately conservative: a game that ALSO uses D3D10/11/12 keeps the GPTK-first path, where DXVK's
    /// extra Vulkan→Metal hop isn't worth paying. (A `d3d8to9` wrapper imports `d3d9`, so a wrapped DX8 game
    /// lands here too — correctly, since that IS the arrangement that reaches DXVK.)
    public var isD3D9Only: Bool { usesD3D9 && !usesD3D1x && !usesD3D12 }

    /// A pure DirectX 8 title. **No backend can help** — wined3d is the correct and only path — so the
    /// reactive ladder must not fire for it, and wine's "Using the Vulkan renderer" line (which wined3d emits
    /// for d3d8 too) is EXPECTED here, not a failure.
    public var isD3D8Only: Bool { usesD3D8 && !usesD3D9 && !usesD3D1x && !usesD3D12 }

    /// A game that drives **Vulkan itself**, with no Direct3D at all. It needs no translation layer, but it
    /// does need a working Vulkan driver — and the wine runtime's own bundled MoltenVK is the STOCK one that
    /// can't serve DXVK. Routing it to the DXVK backend is what puts the DXVK runtime's working MoltenVK
    /// first on the launch's `DYLD_FALLBACK_LIBRARY_PATH`; its seeded d3d dlls simply go unused.
    public var isVulkanNative: Bool {
        usesVulkan && !usesD3D9 && !usesD3D1x && !usesD3D12 && !usesD3D8
    }

    // MARK: - Scanning

    /// Graphics module names, grouped by the tier that can translate them.
    private static let d3d8Names: Set<String> = ["d3d8.dll"]
    private static let d3d9Names: Set<String> = ["d3d9.dll"]
    private static let d3d1xNames: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    private static let d3d12Names: Set<String> = ["d3d12.dll", "d3d12core.dll"]
    private static let vulkanNames: Set<String> = ["vulkan-1.dll"]
    private static let openGLNames: Set<String> = ["opengl32.dll"]

    /// Redistributable DLLs games routinely ship BESIDE their executable. They are not the game's renderer,
    /// but some reference Direct3D and would poison the profile: Microsoft's C++ AMP runtime
    /// (`vcamp140.dll`) imports d3d11 for GPU compute, so a DirectX 9 game that ships the MSVC redist looked
    /// like a D3D11 title and was routed away from DXVK — the only backend that can run it. Found by running
    /// the on-device backend report against a real library. Matched by prefix, lowercased.
    private static let excludedModulePrefixes = [
        "vcamp", "vcomp", "msvcp", "msvcr", "vcruntime", "concrt", "mfc", "ucrtbase", "api-ms-win-",
        "vccorlib", "d3dcompiler_", "x3daudio", "xaudio", "xinput",
    ]

    /// Directory names that hold redistributables/prerequisites rather than the game — their DLLs would
    /// otherwise poison the profile (a bundled DirectX redist references d3d modules the game never uses).
    private static let excludedDirs: Set<String> = [
        "_commonredist", "commonredist", "redist", "_redist", "redistributables",
        "directx", "dotnet", "dotnetfx", "vcredist", "installers", "prerequisites",
    ]

    /// How deep below the executable's own directory to look. 2 covers the layouts that matter — Unity
    /// (`UnityPlayer.dll` beside the exe), Source (`<root>/hl2.exe` + `<root>/bin/shaderapidx9.dll`), and
    /// UE (exe and DLLs together in `Binaries/Win64`) — without walking a whole multi-GB install tree.
    private static let maxDepth = 2
    /// Hard cap on PE files parsed, so a pathological install can't stall a launch. Each parse is a
    /// memory-mapped header read (`WindowsExecutable.importedDLLs`), so this is cheap in practice.
    private static let maxFilesScanned = 256

    /// Whether a DLL is a known redistributable shipped alongside the game rather than part of it.
    static func isRedistributableModule(_ name: String) -> Bool {
        let n = name.lowercased()
        return excludedModulePrefixes.contains { n.hasPrefix($0) }
    }

    /// Build the profile for a game, from its executable plus the DLLs shipped alongside it.
    ///
    /// Synchronous file I/O — call it OFF the main actor (`play`/`playManual` do, in the same detached task
    /// that resolves the exe and reads its bitness). Fail-open throughout: anything unreadable is skipped,
    /// so a weird install yields an `isUnknown` profile and the normal GPTK-first path, never a blocked launch.
    public static func scan(executable exe: URL, fileManager: FileManager = .default) -> D3DProfile {
        var profile = D3DProfile()
        var scanned = 0

        func absorb(_ url: URL) {
            guard scanned < maxFilesScanned else { return }
            scanned += 1
            let imports = WindowsExecutable.importedDLLs(of: url)
            if !imports.isDisjoint(with: d3d8Names) { profile.usesD3D8 = true }
            if !imports.isDisjoint(with: d3d9Names) { profile.usesD3D9 = true }
            if !imports.isDisjoint(with: d3d1xNames) { profile.usesD3D1x = true }
            if !imports.isDisjoint(with: d3d12Names) { profile.usesD3D12 = true }
            if !imports.isDisjoint(with: vulkanNames) { profile.usesVulkan = true }
            if !imports.isDisjoint(with: openGLNames) { profile.usesOpenGL = true }
        }
        /// Nothing further can change the answer once every D3D tier is known (the exclusive `isD3D8Only` /
        /// `isVulkanNative` cases are already ruled out by then, so their flags can't change the routing).
        var isComplete: Bool { profile.usesD3D9 && profile.usesD3D1x && profile.usesD3D12 }

        absorb(exe)                                   // the executable itself, first
        if isComplete { return profile }

        // Then the DLLs around it, nearest first — so the common cases (UnityPlayer.dll, the UE Win64 dir)
        // are found long before the file cap can bite.
        let root = exe.deletingLastPathComponent()
        var levels: [[URL]] = [[root]]
        for depth in 0...maxDepth where depth < levels.count {
            var next: [URL] = []
            for dir in levels[depth] {
                let entries = (try? fileManager.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for entry in entries {
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        guard !excludedDirs.contains(entry.lastPathComponent.lowercased()) else { continue }
                        next.append(entry)
                    } else if entry.pathExtension.lowercased() == "dll",
                              !isRedistributableModule(entry.lastPathComponent) {
                        absorb(entry)
                        if isComplete { return profile }
                    }
                }
                guard scanned < maxFilesScanned else { return profile }
            }
            if depth + 1 <= maxDepth { levels.append(next) }
        }
        return profile
    }
}
