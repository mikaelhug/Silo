import Foundation
import CryptoKit

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
    }

    /// The latest `limit` releases of `repo` (newest first) — for the Heroic-style Wine list.
    public func availableReleases(repo: String, limit: Int = 3) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(limit)")!
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

    /// Wine builds installed under the Runtimes dir (dirs containing a locatable wine binary).
    public func installedWines() -> [WineInstall] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: paths.runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { dir -> WineInstall? in
            guard let binary = Self.locateWineBinary(in: dir) else { return nil }
            return WineInstall(name: dir.lastPathComponent, installDir: dir, wineBinary: binary)
        }.sorted { $0.name > $1.name }   // newest tag first
    }

    /// Download + extract a Wine build and locate its binary.
    @discardableResult
    public func installWine(name: String, from downloadURL: URL) async throws -> WineInstall {
        _ = try await install(name: name, from: downloadURL)   // reuse download + tar extraction
        let dir = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        return WineInstall(name: name, installDir: dir, wineBinary: Self.locateWineBinary(in: dir))
    }

    /// Recursively find a `wine64`/`wine` loader, preferring one under a `bin` directory.
    /// Only matches files/symlinks — NOT directories (e.g. a GPTK runtime's `lib/wine` dir, which
    /// would otherwise make GPTK installs masquerade as Wine).
    public static func locateWineBinary(in dir: URL, fileManager: FileManager = .default) -> URL? {
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

    /// Download an asset and extract it into `Runtimes/<name>` (the shared download+extract engine;
    /// `installWine` wraps it and locates the binary).
    public func install(name: String, from downloadURL: URL) async throws {
        try fileManager.createDirectory(at: paths.runtimesDir, withIntermediateDirectories: true)

        let (tempFile, response) = try await session.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.downloadFailed(http.statusCode)
        }

        let archive = paths.runtimesDir.appendingPathComponent("\(name).archive")
        if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
        try fileManager.moveItem(at: tempFile, to: archive)
        defer { try? fileManager.removeItem(at: archive) }

        // Supply-chain integrity: if a sibling <url>.sha256 exists, the archive must match before we
        // extract + run ~250 MB of unsigned native code. Best-effort (skipped if no digest published).
        if let expected = await expectedSHA256(for: downloadURL) {
            let actual = Self.sha256(ofFileAt: archive)
            guard actual == expected else {
                throw RuntimeError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        let dest = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", dest.path],
            environment: [:], currentDirectory: nil
        )
        guard result.succeeded else {
            try? fileManager.removeItem(at: dest)   // don't leave a half-extracted runtime behind
            throw RuntimeError.extractionFailed(result.exitCode)
        }

        // Downloaded Wine is unsigned and may be quarantined → Gatekeeper blocks it. Strip quarantine
        // and ad-hoc re-sign so it launches on a clean Mac.
        await harden(dest, reSign: true)
    }

    public func remove(name: String) throws {
        let dir = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
    }

    /// Fetch the expected SHA-256 from a sibling `<url>.sha256` (shasum format: "<hex>  filename").
    /// Returns nil if none is published (best-effort verification).
    private func expectedSHA256(for downloadURL: URL) async -> String? {
        let shaURL = downloadURL.appendingPathExtension("sha256")
        guard let (data, response) = try? await session.data(from: shaURL),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { $0.lowercased() }
    }

    /// Streaming SHA-256 of a file (memory-safe for large archives).
    static func sha256(ofFileAt url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// De-quarantine (and optionally ad-hoc re-sign) an extracted runtime tree so macOS will run it.
    func harden(_ dir: URL, reSign: Bool) async {
        _ = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", dir.path],
            environment: [:], currentDirectory: nil)
        if reSign {
            _ = try? await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", "--deep", dir.path],
                environment: [:], currentDirectory: nil)
        }
    }
}
