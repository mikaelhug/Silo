import Foundation

/// Checks GitHub Releases for a newer app build and applies it **inline** (download → in-place swap →
/// relaunch), Sparkle-style but dependency-free: just `URLSession` + `ProcessRunning`. No browser hop,
/// no manual drag-to-Applications.
public struct Updater: Sendable {
    private let repo: String
    private let currentVersion: String
    private let session: URLSession
    private let runner: ProcessRunning

    public init(
        repo: String = Silo.updateRepo,
        currentVersion: String = Silo.version,
        session: URLSession = .shared,
        runner: ProcessRunning = SystemProcessRunner()
    ) {
        self.repo = repo
        self.currentVersion = currentVersion
        self.session = session
        self.runner = runner
    }

    public enum UpdateError: Error, Sendable, Equatable {
        case badResponse(Int)
        case noDownloadAsset
        case unpackFailed
        case notRunningFromBundle
        case replaceFailed
    }

    public struct UpdateCheck: Sendable, Equatable {
        public let latestVersion: String
        public let isNewer: Bool
        public let downloadURL: URL?
        public let releaseName: String?
    }

    public func checkForUpdate() async throws -> UpdateCheck {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await session.data(for: .github(url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        let asset = release.assets.first { $0.name.hasSuffix(".zip") }
        return UpdateCheck(
            latestVersion: release.version,
            isNewer: Self.isVersion(release.version, newerThan: currentVersion),
            downloadURL: asset?.browserDownloadUrl,
            releaseName: release.name
        )
    }

    /// Numeric, component-aware version comparison (`0.10.0` > `0.9.0`).
    static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        candidate.compare(baseline, options: .numeric) == .orderedDescending
    }

    // MARK: - Inline apply (download → in-place swap → relaunch)

    /// Download the update's `.zip` into `directory`, returning the local file URL. Split out from
    /// `installUpdate` so the GUI can show download progress, and so it's testable with a stubbed session.
    public func downloadUpdate(_ check: UpdateCheck, into directory: URL) async throws -> URL {
        guard let url = check.downloadURL else { throw UpdateError.noDownloadAsset }
        let (tempFile, response) = try await session.download(for: .github(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tempFile, to: dest)
        return dest
    }

    /// Unpack the downloaded `.zip` and **atomically replace** `appBundle` with the contained `.app`,
    /// then re-register it with LaunchServices so the new icon/Info.plist take effect immediately. The
    /// staging dir is a sibling of `appBundle` (same volume → `replaceItemAt` is atomic) and is always
    /// cleaned up. Throws rather than half-replacing.
    public func installUpdate(zip: URL, replacing appBundle: URL) async throws {
        let fm = FileManager.default
        let staging = appBundle.deletingLastPathComponent()
            .appendingPathComponent(".silo-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        let unpack = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, staging.path], environment: [:], currentDirectory: nil)
        guard unpack.succeeded,
              let newApp = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed
        }
        do { _ = try fm.replaceItemAt(appBundle, withItemAt: newApp) }
        catch { throw UpdateError.replaceFailed }
        // Best-effort: refresh LaunchServices so Finder/Dock pick up the new bundle metadata.
        _ = try? await runner.run(
            executable: URL(fileURLWithPath: Self.lsregister),
            arguments: ["-f", appBundle.path], environment: [:], currentDirectory: nil)
    }

    /// Launch the (updated) `appBundle` in a fresh process and terminate this one. The side-effectful
    /// tail of the inline update — it ends the process, so it is not unit-tested.
    public func relaunch(_ appBundle: URL) async {
        _ = try? await runner.spawnDetached(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-n", appBundle.path], environment: [:], currentDirectory: nil,
            logURL: FileManager.default.temporaryDirectory.appendingPathComponent("silo-relaunch.log"))
        exit(0)
    }

    /// The enclosing `.app` of the running executable (the bundle to replace), or nil when running
    /// outside a bundle (e.g. `swift run` in development or a CLI invocation) — in which case there is
    /// nothing to swap and the inline update is skipped.
    public static func runningAppBundle() -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main.bundleURL }
        var url = Bundle.main.executableURL ?? Bundle.main.bundleURL
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
}
