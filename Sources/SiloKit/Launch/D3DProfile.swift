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
    /// The game references `d3d9` (the only API DXVK alone can translate — GPTK/DXMT have no d3d9).
    public var usesD3D9 = false
    /// The game references D3D10/10.1/11 — translatable by all three backends.
    public var usesD3D1x = false
    /// The game references D3D12 — **GPTK only**; neither DXMT nor DXVK implements it.
    public var usesD3D12 = false

    public init(usesD3D9: Bool = false, usesD3D1x: Bool = false, usesD3D12: Bool = false) {
        self.usesD3D9 = usesD3D9
        self.usesD3D1x = usesD3D1x
        self.usesD3D12 = usesD3D12
    }

    /// No Direct3D reference found anywhere. Means **unknown**, NOT "no Direct3D": a game can load D3D
    /// dynamically via `LoadLibrary`, or hide it behind a packed/protected binary. Every consumer treats
    /// this as "don't rule anything out" (fail-open), except the DX9-first route which needs positive proof.
    public var isUnknown: Bool { !usesD3D9 && !usesD3D1x && !usesD3D12 }

    /// A pure DirectX 9 title — the one case **only DXVK** can drive (GPTK doesn't translate DX9 at all and
    /// DXMT is D3D10/11-only, so this game would otherwise fall to wined3d and usually black-screen).
    /// Deliberately conservative: a game that ALSO uses D3D10/11/12 keeps the GPTK-first path, where DXVK's
    /// extra Vulkan→Metal hop isn't worth paying.
    public var isD3D9Only: Bool { usesD3D9 && !usesD3D1x && !usesD3D12 }

    // MARK: - Scanning

    /// Direct3D module names, grouped by the tier that can translate them.
    private static let d3d9Names: Set<String> = ["d3d9.dll"]
    private static let d3d1xNames: Set<String> = ["d3d11.dll", "d3d10.dll", "d3d10core.dll", "d3d10_1.dll"]
    private static let d3d12Names: Set<String> = ["d3d12.dll", "d3d12core.dll"]

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
            if !imports.isDisjoint(with: d3d9Names) { profile.usesD3D9 = true }
            if !imports.isDisjoint(with: d3d1xNames) { profile.usesD3D1x = true }
            if !imports.isDisjoint(with: d3d12Names) { profile.usesD3D12 = true }
        }
        /// Nothing further can change the answer once every tier is known.
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
                    } else if entry.pathExtension.lowercased() == "dll" {
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
