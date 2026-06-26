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
    }

    /// Runtimes already extracted under the Runtimes dir.
    public func installedRuntimes() -> [WineRuntime] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { WineRuntime(name: $0.lastPathComponent, installPath: $0, kind: .gptk) }
            .sorted { $0.name < $1.name }
    }

    /// The latest `limit` releases of `repo` (newest first) — for the Heroic-style Wine list.
    public func availableReleases(repo: String, limit: Int = 3) async throws -> [GitHubRelease] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(limit)")!
        let (data, response) = try await session.data(from: url)
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
    public static func locateWineBinary(in dir: URL, fileManager: FileManager = .default) -> URL? {
        guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var candidates: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == "wine64" || url.lastPathComponent == "wine" {
            candidates.append(url)
        }
        func inBin(_ url: URL) -> Bool { url.deletingLastPathComponent().lastPathComponent == "bin" }
        return candidates.first { $0.lastPathComponent == "wine64" && inBin($0) }
            ?? candidates.first { $0.lastPathComponent == "wine64" }
            ?? candidates.first(where: inBin)
            ?? candidates.first
    }

    /// Downloadable assets from the latest release of `repo`.
    public func availableAssets(repo: String) async throws -> [GitHubRelease.Asset] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuntimeError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GitHubRelease.self, from: data).assets
    }

    /// Download an asset and extract it into `Runtimes/<name>`.
    @discardableResult
    public func install(name: String, from downloadURL: URL) async throws -> WineRuntime {
        try fileManager.createDirectory(at: paths.runtimesDir, withIntermediateDirectories: true)

        let (tempFile, response) = try await session.download(from: downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeError.downloadFailed(http.statusCode)
        }

        let archive = paths.runtimesDir.appendingPathComponent("\(name).archive")
        if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
        try fileManager.moveItem(at: tempFile, to: archive)
        defer { try? fileManager.removeItem(at: archive) }

        let dest = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", dest.path],
            environment: [:], currentDirectory: nil
        )
        guard result.succeeded else { throw RuntimeError.extractionFailed(result.exitCode) }

        return WineRuntime(name: name, installPath: dest, kind: .gptk)
    }

    public func remove(name: String) throws {
        let dir = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) { try fileManager.removeItem(at: dir) }
    }
}
