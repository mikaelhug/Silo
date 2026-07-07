import Foundation
import Darwin

/// Prepares the per-backend wine runtime each Steam/manual bottle launches against.
///
/// GPTK and DXMT both overlay a **builtin** `d3d11`/`dxgi` into a runtime's `lib/wine` tree, so a single
/// runtime can't carry both. Each backend therefore needs its own runtime tree:
/// - **GPTK** overlays the installed base runtime *in place* — the proven path, left exactly as it was.
/// - **DXMT** gets an APFS copy-on-write **clone** of the base runtime (`<root>-dxmt`), then DXMT overlaid.
///   The clone is near-free on APFS (only the handful of overlaid files diverge); on a non-APFS / cross-
///   volume target it falls back to a deep copy. The DXMT override set (`GraphicsBackend.dxmt.dllOverrides`)
///   forces D3D10/11 to DXMT's builtins, so any GPTK modules inherited by the clone stay dormant.
///
/// Idempotent — safe to call before every launch: it re-overlays (a no-op if unchanged) and only clones the
/// first time the variant is needed.
public struct RuntimeVariants: Sendable {
    private let linker: GraphicsLinker
    public init(linker: GraphicsLinker = GraphicsLinker()) { self.linker = linker }
    private var fileManager: FileManager { .default }

    public enum VariantError: Error, Sendable, Equatable {
        case cloneFailed(URL, Int32)
    }

    /// The wine binary for `backend`'s overlaid runtime, derived from the installed base runtime.
    /// - Parameters:
    ///   - backend: which translation layer this runtime carries.
    ///   - baseWine: the installed base runtime's wine binary (`BackendConfig.wineBinaryPath`).
    ///   - libDir: that backend's module dir (`BackendConfig.libDir(for:)`), overlaid into the runtime.
    /// - Returns: the wine binary to launch with — the base for GPTK, the DXMT clone for DXMT.
    @discardableResult
    public func prepare(backend: GraphicsBackend, baseWine: URL, libDir: URL) throws -> URL {
        switch backend {
        case .gptk:
            try linker.overlayGPTK(wineBinary: baseWine, gptkLibDir: libDir)
            return baseWine
        case .dxmt:
            let variantWine = try ensureClone(of: baseWine, backend: backend)
            try linker.overlayDXMT(wineBinary: variantWine, dxmtLibDir: libDir)
            return variantWine
        }
    }

    // MARK: - Clone naming (the ONE source of truth for the `<base>-<backend>` sibling scheme)

    /// The runtime-dir name of `backend`'s variant clone of the base runtime `base` — a sibling of the
    /// base under the Runtimes dir. The single place the `-<backend.rawValue>` suffix is formed, so the
    /// exclusion predicate below and the clone location can never drift. Uses `rawValue` ("dxmt"), NOT
    /// `badge` ("DXMT") — the latter is `AppPaths.steamBottle`'s bottle-dir suffix, a different namespace.
    public static func cloneName(ofBase base: String, backend: GraphicsBackend) -> String {
        "\(base)-\(backend.rawValue)"
    }

    /// Whether a Runtimes-dir entry is a variant clone (`<base>-<backend.rawValue>` for any secondary
    /// backend) rather than an installed runtime. `RuntimeManager`'s installed-Wine / installed-DXMT
    /// listings exclude these: a DXMT clone carries both a wine binary AND the overlaid DXMT modules, so
    /// it would otherwise masquerade as an install in BOTH lists.
    public static func isVariantClone(_ name: String) -> Bool {
        GraphicsBackend.allCases.contains { $0 != .gptk && name.hasSuffix("-\($0.rawValue)") }
    }

    // MARK: - Cloning

    private func ensureClone(of baseWine: URL, backend: GraphicsBackend) throws -> URL {
        let baseRoot = WineRuntimeLayout(wineBinary: baseWine).root
        let variantRoot = cloneRoot(of: baseRoot, backend: backend)
        if !fileManager.fileExists(atPath: variantRoot.path) {
            try fileManager.createDirectory(
                at: variantRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cloneTree(from: baseRoot, to: variantRoot)
        }
        return variantRoot.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(baseWine.lastPathComponent)
    }

    private func cloneRoot(of baseRoot: URL, backend: GraphicsBackend) -> URL {
        baseRoot.deletingLastPathComponent()
            .appendingPathComponent(
                Self.cloneName(ofBase: baseRoot.lastPathComponent, backend: backend), isDirectory: true)
    }

    /// Clone `src` into a private staging dir, then publish it to `dst` with an atomic rename — so `dst`
    /// only ever appears as a COMPLETE tree. This makes concurrent first-time launches of two DXMT games
    /// race-safe (the loser finds `dst` already published and reuses it, instead of its fallback copy hitting
    /// EEXIST) and prevents a hard-killed mid-clone from leaving a partial tree that later launches would
    /// silently reuse (it stays an ignored `.cloning-*` temp). APFS copy-on-write (`clonefile`) into the
    /// staging dir, falling back to a deep copy on a non-APFS / cross-volume target.
    private func cloneTree(from src: URL, to dst: URL) throws {
        let staging = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).cloning-\(UUID().uuidString)", isDirectory: true)
        let rc = src.path.withCString { s in staging.path.withCString { d in clonefile(s, d, 0) } }
        if rc != 0 {
            do {
                try fileManager.copyItem(at: src, to: staging)
            } catch {
                try? fileManager.removeItem(at: staging)
                // Surface the underlying POSIX code from the copy failure (not the process-global `errno`,
                // which the Foundation call above may have overwritten since the `clonefile` return).
                let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                throw VariantError.cloneFailed(dst, Int32(posix ?? Int(errno)))
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: dst)   // atomic publish
        } catch {
            // Lost the race — another launch already published an identical clone. Use theirs; only a
            // still-absent `dst` is a real failure.
            try? fileManager.removeItem(at: staging)
            guard fileManager.fileExists(atPath: dst.path) else { throw error }
        }
    }
}
