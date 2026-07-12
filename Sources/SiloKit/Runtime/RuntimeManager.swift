import Foundation

/// Downloads and manages Wine/GPTK runtimes under the Runtimes dir (Heroic-style), with zero
/// dependency on Homebrew. Metadata + download use `URLSession`; extraction uses `tar` via the
/// `ProcessRunning` seam so it's testable without a real archive.
public actor RuntimeManager {
    private let paths: AppPaths
    private let runner: ProcessRunning
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        paths: AppPaths,
        runner: ProcessRunning,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.runner = runner
        self.session = session
        self.fileManager = fileManager
    }

    public enum RuntimeError: Error, Sendable, Equatable {
        case badResponse(Int)
        case downloadFailed(Int)
        case extractionFailed(Int32)
        case checksumMismatch(expected: String, actual: String)
        /// No `<url>.sha256` was published but a digest is required for this repo (the built-in repo —
        /// see `requireDigest`). Never silently downgrade integrity for code we point users at.
        case checksumUnavailable
        /// The release name/tag couldn't be reduced to a safe single path component (path-traversal
        /// attempt, e.g. a release literally named `../../evil`). See `safeRuntimeComponent`.
        case unsafeRuntimeName(String)
    }

    /// A release tag is a flat label, never a path. Reduce it to a single safe path component
    /// (strip path separators, leading dots, NUL); returns nil if nothing safe remains.
    static func safeRuntimeComponent(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: "\0", with: "")
        guard !cleaned.contains("/"), cleaned != "." , cleaned != "..",
              !cleaned.hasPrefix(".."), !cleaned.isEmpty else { return nil }
        return cleaned
    }

    /// The latest `limit` releases of `repo` (newest first) — for the Heroic-style Wine list.
    public func availableReleases(repo: String, limit: Int = 3) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(limit)")!
        try DownloadGuard.requireHTTPS(url)   // defense-in-depth: every remote fetch goes through the guard
        let (data, response) = try await session.data(for: .github(url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([GitHubRelease].self, from: data)
    }

    /// The installable archive asset of a release (prefers tar/zip archives).
    public static func preferredAsset(_ release: GitHubRelease) -> GitHubRelease.Asset? {
        let extensions = [".tar.xz", ".tar.gz", ".tgz", ".tar", ".zip"]
        return release.assets.first { asset in
            extensions.contains { asset.name.lowercased().hasSuffix($0) }
        }
    }

    /// Wine builds installed under the Runtimes dir (dirs containing a locatable wine binary). Excludes
    /// a backend's variant CLONE (`<base>-dxmt`): the clone carries a wine binary too, so without this
    /// filter a DXMT clone would masquerade as a separate installed Wine (see `RuntimeVariants`).
    public func installedWines() -> [WineInstall] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: paths.runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { dir -> WineInstall? in
            guard !RuntimeVariants.isVariantClone(dir.lastPathComponent),
                  let binary = Self.locateWineBinary(in: dir) else { return nil }
            return WineInstall(name: dir.lastPathComponent, installDir: dir, wineBinary: binary)
        }.sorted { $0.name > $1.name }   // newest tag first
    }

    /// Download + extract a Wine build and locate its binary. `requireDigest` mandates a published
    /// `<url>.sha256` (fail-closed) when installing from the built-in repo; pass `false` only for a
    /// user-overridden custom repo (best-effort, mirroring the legacy behavior).
    @discardableResult
    public func installWine(
        name: String, from downloadURL: URL, requireDigest: Bool = false
    ) async throws -> WineInstall {
        let safe = try Self.requireSafeComponent(name)
        _ = try await install(name: safe, from: downloadURL, requireDigest: requireDigest)
        let dir = paths.runtimesDir.appendingPathComponent(safe, isDirectory: true)
        return WineInstall(name: safe, installDir: dir, wineBinary: Self.locateWineBinary(in: dir))
    }

    /// `safeRuntimeComponent` or throw — the boundary check applied before any tag/name builds a path.
    private static func requireSafeComponent(_ name: String) throws -> String {
        guard let safe = safeRuntimeComponent(name) else {
            throw RuntimeError.unsafeRuntimeName(name)
        }
        return safe
    }

    /// Recursively find a `wine64`/`wine` loader, preferring one under a `bin` directory.
    /// Only matches files/symlinks — NOT directories (e.g. a GPTK runtime's `lib/wine` dir, which
    /// would otherwise make GPTK installs masquerade as Wine).
    public static func locateWineBinary(in dir: URL, fileManager: FileManager = .default) -> URL? {
        // Fast path: the standard runtime layout puts the loader at <root>/bin/wine64 (the walk's own top
        // preference). Return it directly so the common case doesn't enumerate the whole runtime (thousands
        // of lib/wine PE files) — a real cost at bootstrap, worse on a slow external volume.
        let standard = dir.appendingPathComponent("bin/wine64")
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: standard.path, isDirectory: &isDir), !isDir.boolValue { return standard }

        guard let enumerator = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        var candidates: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == "wine64" || url.lastPathComponent == "wine" {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { candidates.append(url) }
        }
        func inBin(_ url: URL) -> Bool { url.deletingLastPathComponent().lastPathComponent == "bin" }
        return candidates.first { $0.lastPathComponent == "wine64" && inBin($0) }
            ?? candidates.first { $0.lastPathComponent == "wine64" }
            ?? candidates.first(where: inBin)
            ?? candidates.first
    }

    // MARK: - DXMT (reuses the same download+extract+harden engine as Wine)

    /// A DXMT runtime's module dir inside an extracted release — the `x86_64-windows` folder, found by its
    /// signature files (`d3d11.dll` + `winemetal.dll`) rather than assuming the exact tree depth. The DXMT
    /// counterpart of `locateWineBinary`.
    public static func locateDXMTLibDir(in dir: URL, fileManager: FileManager = .default) -> URL? {
        // Fast path: the standard DXMT layout is <root>/lib/wine/x86_64-windows.
        let standard = dir.appendingPathComponent("lib/wine/x86_64-windows")
        if fileManager.fileExists(atPath: standard.appendingPathComponent("winemetal.dll").path),
           fileManager.fileExists(atPath: standard.appendingPathComponent("d3d11.dll").path) { return standard }

        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "winemetal.dll" {
            let parent = url.deletingLastPathComponent()
            if fileManager.fileExists(atPath: parent.appendingPathComponent("d3d11.dll").path) { return parent }
        }
        return nil
    }

    /// DXMT builds installed under the Runtimes dir (dirs containing a locatable DXMT module dir).
    /// Excludes a backend's variant CLONE (`<base>-dxmt`): the clone has the DXMT modules overlaid into
    /// it, so without this filter it would masquerade as a standalone installed DXMT runtime.
    public func installedDXMT() -> [DXMTInstall] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: paths.runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { dir -> DXMTInstall? in
            guard !RuntimeVariants.isVariantClone(dir.lastPathComponent),
                  let lib = Self.locateDXMTLibDir(in: dir) else { return nil }
            return DXMTInstall(name: dir.lastPathComponent, installDir: dir, libDir: lib)
        }.sorted { $0.name > $1.name }   // newest tag first
    }

    /// Download + extract a DXMT build and locate its module dir — the DXMT counterpart of `installWine`,
    /// sharing the exact same `install` engine (HTTPS-only, mandatory/best-effort SHA-256, safe extract,
    /// de-quarantine + ad-hoc sign — `winemetal.so` needs the hardening just like Wine).
    @discardableResult
    public func installDXMT(
        name: String, from downloadURL: URL, requireDigest: Bool = false
    ) async throws -> DXMTInstall {
        let safe = try Self.requireSafeComponent(name)
        try await install(name: safe, from: downloadURL, requireDigest: requireDigest)
        let dir = paths.runtimesDir.appendingPathComponent(safe, isDirectory: true)
        return DXMTInstall(name: safe, installDir: dir, libDir: Self.locateDXMTLibDir(in: dir))
    }

    /// Pick the DXMT release to install for a given wine. DXMT releases are tagged
    /// `dxmt-<ver>-cx<wine version>`, so prefer the one built against `wineRuntimeName` (e.g.
    /// `wine-cx-26.2.0`) to keep the winemetal.so↔wine ABI paired; fall back to the newest `dxmt-*`
    /// (GitHub returns releases newest-first) when there's no exact match or no wine is set. Pure.
    public static func matchedDXMTRelease(
        _ releases: [GitHubRelease], forWine wineRuntimeName: String?
    ) -> GitHubRelease? {
        let dxmt = releases.filter { $0.tagName.lowercased().hasPrefix("dxmt") }
        if let cx = wineRuntimeName.flatMap(wineCXVersion),
           let matched = dxmt.first(where: { $0.tagName.hasSuffix("-cx\(cx)") }) {
            return matched
        }
        return dxmt.first
    }

    /// The source version embedded in a wine runtime name (`wine-cx-26.2.0` → `26.2.0`), or nil.
    static func wineCXVersion(_ runtimeName: String) -> String? {
        let prefix = "wine-cx-"
        return runtimeName.hasPrefix(prefix) ? String(runtimeName.dropFirst(prefix.count)) : nil
    }

    // MARK: - Shared download engine

    /// Download an asset and extract it into `Runtimes/<name>` (the shared download+extract engine;
    /// `installWine` / `installDXMT` wrap it and locate the binary / module dir). `name` is sanitized to a
    /// single safe path component before it builds any path (path-traversal defense). When `requireDigest`
    /// is true a published `<url>.sha256` is mandatory (fail-closed) — see the integrity check below.
    public func install(name: String, from downloadURL: URL, requireDigest: Bool = false) async throws {
        let safeName = try Self.requireSafeComponent(name)
        try DownloadGuard.requireHTTPS(downloadURL)   // reject http/file/other before any network call
        try fileManager.createDirectory(at: paths.runtimesDir, withIntermediateDirectories: true)

        let (tempFile, response) = try await session.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.downloadFailed(http.statusCode)
        }

        let archive = paths.runtimesDir.appendingPathComponent("\(safeName).archive")
        if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
        try fileManager.moveItem(at: tempFile, to: archive)
        defer { try? fileManager.removeItem(at: archive) }

        // Supply-chain integrity: an archive must match its published <url>.sha256 before we extract +
        // run ~250 MB of unsigned native code. For the built-in repo the digest is MANDATORY
        // (`requireDigest`) — never silently downgrade integrity for code we point users at; for a
        // user's own override it stays best-effort (skipped if no digest published). NB: a matching
        // digest defeats MITM/CDN tampering, NOT a compromised release (the digest ships from the same
        // place) — that requires notarization (separate, human-gated).
        if let expected = await expectedSHA256(for: downloadURL) {
            let actual = try FileDigest.sha256(ofFileAt: archive)
            guard actual == expected else {
                throw RuntimeError.checksumMismatch(expected: expected, actual: actual)
            }
        } else if requireDigest {
            throw RuntimeError.checksumUnavailable
        }

        let dest = paths.runtimesDir.appendingPathComponent(safeName, isDirectory: true)
        // Belt-and-suspenders: the extraction target must stay inside the Runtimes dir.
        let runtimesPath = paths.runtimesDir.standardizedFileURL.path
        guard dest.standardizedFileURL.path.hasPrefix(runtimesPath) else {
            throw RuntimeError.unsafeRuntimeName(name)
        }

        // Extract into a private staging dir, then publish to `dest` with an atomic rename — so a reinstall
        // of an existing name never merges stale files over the old tree, and a mid-extract failure leaves
        // any existing good install untouched (the old path extracted in place + removed `dest` on failure).
        let staging = paths.runtimesDir
            .appendingPathComponent(".\(safeName).extracting-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }   // cleaned on any failure, or after the move

        // The name check above validates only the destination NAME; protection against `../` entries INSIDE
        // the archive rests on two layers: (1) the archive's integrity is verified first (mandatory SHA-256
        // for the built-in repo, `requireDigest`), and (2) macOS `bsdtar` (libarchive) refuses upward
        // traversal by default — we never pass `-P`/`--absolute-paths`. A custom repo with best-effort digests
        // still gets layer (2).
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", staging.path],
            environment: [:], currentDirectory: nil
        )
        guard result.succeeded else { throw RuntimeError.extractionFailed(result.exitCode) }

        // winebus's SDL controller backend dlopens libSDL2, whose macOS initializer pops an NSAlert off the
        // main thread → the WHOLE Wine process aborts the instant winebus loads (before Steam draws). Runtimes
        // built before `--without-sdl` bundle libSDL2; strip it so a downloaded runtime can't crash on launch,
        // with no Wine rebuild required.
        Self.stripBundledSDL(in: staging, fileManager: fileManager)

        // Downloaded Wine is unsigned + quarantined → Gatekeeper blocks it until the quarantine flag is
        // stripped (x86_64 runs unsigned, so no signing is needed — see `deQuarantine`). Best-effort, but
        // remember a failure so the installing UI can warn instead of leaving a later block unexplained.
        lastHardeningIssue = await deQuarantine(staging, using: runner).issue(for: dest)

        // Atomic publish: replace any prior install only now that the staged tree is complete + hardened.
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        try fileManager.moveItem(at: staging, to: dest)
    }

    /// The warning from the most recent install's hardening pass, or nil when it applied cleanly.
    public private(set) var lastHardeningIssue: String?

    /// Remove any bundled `libSDL2*` from a runtime (see `install`). Searches the runtime's dylib tree
    /// (`lib/`) — covering Silo's `lib/silo-bundled` AND a custom-repo runtime that bundles it elsewhere —
    /// while PRUNING the large `lib/wine` PE-module subtree, where a loadable dylib never lives. That keeps it
    /// cheap even on a slow external volume (the built-in repo builds `--without-sdl`, so it usually finds
    /// nothing, and shouldn't pay to walk thousands of PE files to learn that). Idempotent; no-op if absent.
    @discardableResult
    static func stripBundledSDL(in runtimeDir: URL, fileManager: FileManager = .default) -> Int {
        let libDir = runtimeDir.appendingPathComponent("lib", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: libDir, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == "wine" { enumerator.skipDescendants(); continue }   // prune the PE tree
            if url.lastPathComponent.lowercased().hasPrefix("libsdl2"),
               (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Remove an installed runtime, plus any secondary-backend variant CLONE derived from it
    /// (`<name>-dxmt`). The clone is derived state: `RuntimeVariants.ensureClone` keeps an EXISTING clone
    /// untouched, so a clone whose base was removed can never be re-adopted — leaving it behind is
    /// permanent dead weight. (A launch re-derives a fresh clone from whatever base is current.)
    public func remove(name: String) throws {
        let dir = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
        for backend in GraphicsBackend.allCases where backend != .gptk {
            let clone = paths.runtimesDir.appendingPathComponent(
                RuntimeVariants.cloneName(ofBase: name, backend: backend), isDirectory: true)
            if fileManager.fileExists(atPath: clone.path) { try fileManager.removeItem(at: clone) }
        }
    }

    /// Fetch the expected SHA-256 from a sibling `<url>.sha256` (shasum format: "<hex>  filename").
    /// Returns nil if none is published (best-effort verification).
    private func expectedSHA256(for downloadURL: URL) async -> String? {
        let shaURL = downloadURL.appendingPathExtension("sha256")
        guard (try? DownloadGuard.requireHTTPS(shaURL)) != nil,
              let (data, response) = try? await session.data(from: shaURL),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { $0.lowercased() }
    }

}
